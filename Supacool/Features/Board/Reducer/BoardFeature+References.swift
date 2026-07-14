import ComposableArchitecture
import Foundation

private nonisolated let boardLogger = SupaLogger("Board")

/// The session-reference scanning + per-session PR-status reducer handlers
/// and the shared PR-refresh effect, mechanically extracted from
/// `BoardFeature.swift`; behavior identical.
extension BoardFeature {
  func reduceCardAppeared(state: inout State, id: AgentSession.ID) -> Effect<Action> {
    guard let session = state.sessions.first(where: { $0.id == id }) else {
      return .none
    }
    // Re-scan when the references cache is missing OR the session has
    // had activity since the last scan. This keeps the transcript-
    // extracted refs (tickets, PR URLs) fresh after the agent writes
    // something new without spamming scans on every board render.
    //
    // PR state refresh used to live here as well — it now lives in
    // the global `_runPRRefreshTick` scheduler so a single periodic
    // tick fetches each unique PR once across the whole board with
    // bounded concurrency. Spawning per-session per-cardAppeared was
    // architecturally wrong: it produced 200+ concurrent `gh pr
    // view` subprocesses when many sessions referenced the same
    // PRs and refreshed in lockstep on every busy↔idle transition.
    let needsScan = session.referencesScannedAt == nil
      || session.lastActivityAt > (session.referencesScannedAt ?? .distantPast)
    guard needsScan else { return .none }
    let worktreeID = session.worktreeID
    let agentID = session.agentNativeSessionID
    let initialPrompt = session.initialPrompt
    // Chip parsing is scoped to this session's repo team keys (e.g.
    // `CEN`), so a multi-team workspace doesn't surface noise like
    // `HTTP-200`. An unconfigured repo yields an empty set = match any.
    @Shared(.repositorySettings(URL(fileURLWithPath: session.repositoryID)))
    var repositorySettings
    let allowedPrefixes = parseLinearTeamKeys(repositorySettings.linearTeamKeys)
    return .run { [scannerClient] send in
      var refs: [SessionReference] = []
      if let agentID, !agentID.isEmpty {
        refs = await scannerClient.scan(worktreeID, agentID, allowedPrefixes)
      }
      // Always also scan the initialPrompt and Supacool's own
      // terminal transcript. The transcript pass catches Codex/raw
      // terminal refs that never land in Claude's native JSONL.
      let promptRefs = scannerClient.scanText(initialPrompt, allowedPrefixes)
      let terminalRefs = await scannerClient.scanTerminalTranscript(id, allowedPrefixes)
      let merged = Self.mergeReferences(
        Self.mergeReferences(refs, with: promptRefs),
        with: terminalRefs
      )
      await send(._referencesScanned(id: id, refs: merged))
    }
  }

  func reduceReferencesScanned(
    state: inout State,
    id: AgentSession.ID,
    refs: [SessionReference]
  ) -> Effect<Action> {
    state.$sessions.withLock { sessions in
      guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
      let dismissed = sessions[index].dismissedReferenceKeys
      let merged = Self.mergeReferences(
        refs,
        with: sessions[index].references,
        preferNewStates: true
      )
      // Honor user unlinks: never re-surface a reference the user
      // explicitly removed, even if it is still in the transcript.
      sessions[index].references = merged.filter { !dismissed.contains($0.dedupeKey) }
      sessions[index].referencesScannedAt = Date()
    }
    // No per-scan PR-refresh dispatch here anymore — the global
    // `_runPRRefreshTick` scheduler picks up newly-discovered and
    // still-active refs on its next tick. This eliminates the
    // multi-session lockstep storm where every busy↔idle edge
    // re-fetched the same PRs once per referencing session.
    return .none
  }

  func reduceRemoveReference(state: inout State, id: AgentSession.ID, dedupeKey: String) -> Effect<Action> {
    state.$sessions.withLock { sessions in
      guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
      sessions[index].references.removeAll { $0.dedupeKey == dedupeKey }
      sessions[index].dismissedReferenceKeys.insert(dedupeKey)
    }
    return .none
  }

  func reduceRefreshPRReferences(state: inout State, id: AgentSession.ID) -> Effect<Action> {
    let batch = Self.pickPRRefreshCandidates(
      sessions: state.sessions,
      sessionID: id,
      mode: .visible,
      lastFailureAt: state.prRefreshFailureAt,
      lastSuccessAt: state.prRefreshSuccessAt,
      jitter: state.prRefreshFailureJitter,
      inFlight: state.prRefreshInFlight,
      now: date.now
    )
    guard !batch.isEmpty else { return .none }
    return prRefreshEffect(batch: batch, previousSnapshots: state.prReferenceSnapshots)
  }

  func reduceRefreshPRStatus(
    state: inout State,
    id: AgentSession.ID,
    ref: SessionReference
  ) -> Effect<Action> {
    guard case .pullRequest(let owner, let repo, let number, _, _) = ref else {
      return .none
    }
    return .run { [githubCLI] send in
      do {
        // Race the gh subprocess against a wall-clock timeout.
        // Without this, a `gh pr view` that hangs (network stall,
        // or its own `zsh -l` startup blocked on a fork() EAGAIN
        // under proc-table pressure) never returns success OR
        // failure. The failure cache below only populates from the
        // catch path, so a hung subprocess means the same PR ref
        // gets re-spawned on every cardAppeared wave. We saw 377
        // accumulated stuck gh wrappers in the wild before this
        // fix; the cumulative slot consumption then *causes* more
        // forks to fail, so the storm self-reinforces.
        let snapshot = try await withThrowingTaskGroup(of: PullRequestSnapshot.self) {
          group in
          group.addTask {
            try await githubCLI.viewPullRequest(owner, repo, number)
          }
          group.addTask {
            try await Task.sleep(for: Self.prRefreshTimeout)
            throw PRRefreshTimeoutError()
          }
          defer { group.cancelAll() }
          guard let result = try await group.next() else {
            throw PRRefreshTimeoutError()
          }
          return result
        }
        await send(._prStatusUpdated(id: id, ref: ref, snapshot: snapshot))
      } catch {
        boardLogger.warning(
          "Failed to fetch PR state for \(owner)/\(repo)#\(number): \(error)"
        )
        await send(._prRefreshFailed(refKey: ref.dedupeKey))
      }
    }
    .cancellable(id: PRRefreshCancelID(refKey: ref.dedupeKey), cancelInFlight: true)
  }

  func reducePRRefreshFailed(state: inout State, refKey: String) -> Effect<Action> {
    // Record the failure timestamp + a random per-ref jitter so the
    // next tick's cooldown filter spreads retries instead of letting
    // N synchronous failures produce N synchronous retries.
    state.prRefreshFailureAt[refKey] = date.now
    state.prRefreshFailureJitter[refKey] = Double.random(
      in: 0...Self.prRefreshFailureJitterMax
    )
    state.prRefreshInFlight.remove(refKey)
    return .none
  }

  func reducePRStatusUpdated(
    state: inout State,
    id: AgentSession.ID,
    ref: SessionReference,
    snapshot: PullRequestSnapshot
  ) -> Effect<Action> {
    let outcome = Self.pullRequestReturnOutcome(
      refKey: ref.dedupeKey,
      previous: state.prReferenceSnapshots[ref.dedupeKey],
      next: snapshot,
      sessions: state.sessions,
      autoResume: AutoResumeSettings.load(),
      priorAttempts: state.autoResumeAttempts[ref.dedupeKey] ?? 0,
      maxAttempts: Self.autoResumeMaxAttempts
    )
    state.$sessions.withLock { sessions in
      guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
      sessions[index].references = sessions[index].references.map { existing in
        existing.dedupeKey == ref.dedupeKey
          ? Self.updatingPRSnapshot(of: existing, to: snapshot)
          : existing
      }
    }
    state.prReferenceSnapshots[ref.dedupeKey] = snapshot
    state.prRefreshFailureAt.removeValue(forKey: ref.dedupeKey)
    state.prRefreshFailureJitter.removeValue(forKey: ref.dedupeKey)
    state.prRefreshSuccessAt[ref.dedupeKey] = date.now
    return Self.applyPRReturnOutcome(outcome, refKey: ref.dedupeKey, next: snapshot, into: &state)
  }

  /// Shared effect body for scheduled and user-visible PR refreshes.
  /// Bounded TaskGroup keeps the `gh pr view` subprocess count capped.
  /// Overlap between a scheduler tick and a popover-driven refresh is
  /// handled by the `prRefreshInFlight` dedupe in `pickPRRefreshCandidates`,
  /// not by cancellation — see the `cancelInFlight: false` note below for
  /// why tearing a batch down mid-flight would strand in-flight keys.
  func prRefreshEffect(
    batch: [PRRefreshCandidate],
    previousSnapshots: [String: PullRequestSnapshot]
  ) -> Effect<Action> {
    .run { [githubCLI, prMonitor, clock] send in
      await withTaskGroup(of: Void.self) { group in
        var iter = batch.makeIterator()
        var active = 0
        while active < Self.prRefreshConcurrencyCap, let next = iter.next() {
          await send(._prRefreshStarted(refKey: next.refKey))
          group.addTask {
            await Self.fetchPRWithTimeout(
              refKey: next.refKey,
              owner: next.owner,
              repo: next.repo,
              number: next.number,
              previous: previousSnapshots[next.refKey],
              githubCLI: githubCLI,
              prMonitor: prMonitor,
              clock: clock,
              send: send
            )
          }
          active += 1
        }
        while await group.next() != nil {
          active -= 1
          if let next = iter.next() {
            await send(._prRefreshStarted(refKey: next.refKey))
            group.addTask {
              await Self.fetchPRWithTimeout(
                refKey: next.refKey,
                owner: next.owner,
                repo: next.repo,
                number: next.number,
                previous: previousSnapshots[next.refKey],
                githubCLI: githubCLI,
                prMonitor: prMonitor,
                clock: clock,
                send: send
              )
            }
            active += 1
          }
        }
      }
    }
    // `cancelInFlight: false` is load-bearing, not a default. This effect
    // inserts each refKey into `prRefreshInFlight` via `_prRefreshStarted`
    // and only ever removes it via the terminal `_prStateFanout` /
    // `_prRefreshFailed` sends. TCA's `Send` opens with
    // `guard !Task.isCancelled` — so if a tick or popover-driven refresh
    // tore down a still-fetching batch (both call sites share this id), the
    // terminal send is swallowed and the key is stranded in-flight forever.
    // `pickPRRefreshCandidates` then permanently skips it, freezing that PR
    // at its last state (e.g. a merged PR stuck rendering OPEN/green). Letting
    // batches always drain is safe: the in-flight set already dedupes work, so
    // overlapping batches skip each other's keys instead of racing.
    .cancellable(id: PRRefresherTickCancelID(), cancelInFlight: false)
  }
}

/// Cancel ID for the legacy one-session `_refreshPRStatus` effect.
/// Keyed by the PR's `dedupeKey` so a later scoped refresh cancels the
/// prior gh subprocess instead of stacking another one on top.
private nonisolated struct PRRefreshCancelID: Hashable, Sendable {
  let refKey: String
}

/// Cancel ID for the in-flight PR-refresh worker effect. Registered so the
/// batch can be torn down on store teardown, but dispatched with
/// `cancelInFlight: false`: a new scheduled or user-visible refresh must NOT
/// cancel a still-fetching batch, because cancellation swallows the terminal
/// `_prStateFanout` / `_prRefreshFailed` send (TCA `Send` no-ops once
/// `Task.isCancelled`) and strands the refKey in `prRefreshInFlight` forever.
private nonisolated struct PRRefresherTickCancelID: Hashable, Sendable {}
