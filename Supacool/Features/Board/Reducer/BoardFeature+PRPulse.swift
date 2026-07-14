import ComposableArchitecture
import Foundation
import IdentifiedCollections

private nonisolated let boardLogger = SupaLogger("Board")

/// The PR Pulse reducer handlers + fetch machinery, mechanically extracted
/// from `BoardFeature.swift`; behavior identical.
extension BoardFeature {
  // MARK: - Global PR refresh scheduler
  //
  // One scheduler per app lifetime. Walks all sessions, dedupes
  // unresolved/open/draft PR refs by dedupeKey, filters by cooldown +
  // success-cache + in-flight set, then fetches up to `prRefreshConcurrencyCap`
  // at a time using a bounded TaskGroup. Results fan out via
  // `_prStateFanout` so every session referencing the same PR
  // gets the new state from a single network round-trip.

  func reduceStartPRRefresher(state: inout State) -> Effect<Action> {
    guard !state.prRefreshSchedulerStarted else { return .none }
    state.prRefreshSchedulerStarted = true
    return .merge(
      .run { [clock] send in
        while !Task.isCancelled {
          do {
            try await clock.sleep(for: Self.prRefreshInterval)
          } catch {
            return
          }
          await send(._runPRRefreshTick)
        }
      }
      .cancellable(id: PRRefresherCancelID(), cancelInFlight: true),
      .run { [clock] send in
        while !Task.isCancelled {
          do {
            try await clock.sleep(for: Self.prPulseInterval)
          } catch {
            return
          }
          await send(._runPRPulseTick)
        }
      }
      .cancellable(id: PRPulseTickerCancelID(), cancelInFlight: true)
    )
  }

  func reduceRunPRRefreshTick(state: inout State) -> Effect<Action> {
    // Collect unique active PR refs across all sessions. `nil` refs
    // get resolved, and OPEN/DRAFT refs are re-checked so a PR that
    // was closed/merged externally does not stay green forever.
    let batch = Self.pickPRRefreshCandidates(
      sessions: state.sessions,
      sessionID: nil,
      mode: .automatic,
      lastFailureAt: state.prRefreshFailureAt,
      lastSuccessAt: state.prRefreshSuccessAt,
      jitter: state.prRefreshFailureJitter,
      inFlight: state.prRefreshInFlight,
      now: date.now
    )
    guard !batch.isEmpty else { return .none }
    return prRefreshEffect(batch: batch, previousSnapshots: state.prReferenceSnapshots)
  }

  func reducePRRefreshStarted(state: inout State, refKey: String) -> Effect<Action> {
    state.prRefreshInFlight.insert(refKey)
    return .none
  }

  func reducePRStateFanout(
    state: inout State,
    refKey: String,
    snapshot: PullRequestSnapshot
  ) -> Effect<Action> {
    // Apply the fetched state to every session that references this
    // PR. Single network result, all sessions updated.
    let outcome = Self.pullRequestReturnOutcome(
      refKey: refKey,
      previous: state.prReferenceSnapshots[refKey],
      next: snapshot,
      sessions: state.sessions,
      autoResume: AutoResumeSettings.load(),
      priorAttempts: state.autoResumeAttempts[refKey] ?? 0,
      maxAttempts: Self.autoResumeMaxAttempts
    )
    state.$sessions.withLock { sessions in
      for index in sessions.indices {
        sessions[index].references = sessions[index].references.map { ref in
          ref.dedupeKey == refKey
            ? Self.updatingPRSnapshot(of: ref, to: snapshot)
            : ref
        }
      }
    }
    state.prReferenceSnapshots[refKey] = snapshot
    state.prRefreshFailureAt.removeValue(forKey: refKey)
    state.prRefreshFailureJitter.removeValue(forKey: refKey)
    state.prRefreshSuccessAt[refKey] = date.now
    state.prRefreshInFlight.remove(refKey)
    return Self.applyPRReturnOutcome(outcome, refKey: refKey, next: snapshot, into: &state)
  }

  // MARK: - PR Pulse (repo-wide open-PR monitoring)

  func reducePRPulseRepositoriesChanged(
    state: inout State,
    targets: [PRPulseTarget]
  ) -> Effect<Action> {
    let known = Set(state.prPulseTargets.map(\.repositoryID))
    let current = Set(targets.map(\.repositoryID))
    state.prPulseTargets = targets
    // Drop bookkeeping for repos removed from the board.
    state.prPulseSnapshots = state.prPulseSnapshots.filter { current.contains($0.key) }
    state.prPulseSuccessAt = state.prPulseSuccessAt.filter { current.contains($0.key) }
    state.prPulseFailureAt = state.prPulseFailureAt.filter { current.contains($0.key) }
    state.$prPulseIgnoredPRKeys.withLock { keys in
      keys.removeAll { key in
        !current.contains { PRPulseIgnoreKey.belongs(key, to: $0) }
      }
    }
    // Fetch newly registered repos right away instead of waiting up
    // to a full tick for the badge to populate.
    let fresh = targets.filter {
      !known.contains($0.repositoryID) && !state.prPulseInFlight.contains($0.repositoryID)
    }
    guard !fresh.isEmpty else { return .none }
    return .merge(fresh.map { prPulseFetchEffect(target: $0, previous: nil) })
  }

  func reducePRPulseRefreshRequested(state: inout State) -> Effect<Action> {
    // The user explicitly asked — failure cooldowns don't apply, but
    // a short throttle still guards against click-spamming.
    state.prPulseFailureAt = [:]
    let due = Self.pickPRPulseDueTargets(
      targets: state.prPulseTargets,
      inFlight: state.prPulseInFlight,
      successAt: state.prPulseSuccessAt,
      failureAt: state.prPulseFailureAt,
      freshness: Self.prPulseManualThrottle,
      now: date.now
    )
    guard !due.isEmpty else { return .none }
    return .merge(
      due.map { prPulseFetchEffect(target: $0, previous: state.prPulseSnapshots[$0.repositoryID]) }
    )
  }

  func reduceRunPRPulseTick(state: inout State) -> Effect<Action> {
    let due = Self.pickPRPulseDueTargets(
      targets: state.prPulseTargets,
      inFlight: state.prPulseInFlight,
      successAt: state.prPulseSuccessAt,
      failureAt: state.prPulseFailureAt,
      freshness: Self.prPulseFreshnessWindow,
      now: date.now
    )
    guard !due.isEmpty else { return .none }
    return .merge(
      due.map { prPulseFetchEffect(target: $0, previous: state.prPulseSnapshots[$0.repositoryID]) }
    )
  }

  func reducePRPulseFetchStarted(state: inout State, repositoryID: String) -> Effect<Action> {
    state.prPulseInFlight.insert(repositoryID)
    return .none
  }

  func reducePRPulseSnapshotLoaded(
    state: inout State,
    snapshot: RepoPullRequestSnapshot
  ) -> Effect<Action> {
    var snapshot = snapshot
    state.prPulseInFlight.remove(snapshot.repositoryID)
    state.prPulseFailureAt.removeValue(forKey: snapshot.repositoryID)
    state.prPulseSuccessAt[snapshot.repositoryID] = date.now
    // The repo may have been removed from the board while the fetch
    // was in flight; don't resurrect its snapshot.
    if state.prPulseTargets.contains(where: { $0.repositoryID == snapshot.repositoryID }) {
      snapshot.fetchedAt = date.now
      state.prPulseSnapshots[snapshot.repositoryID] = snapshot
      // Drop ignore keys for this repo's PRs that are no longer open
      // (merged/closed) so the "N ignored" count stays truthful.
      let live = Set(
        snapshot.pullRequests.map {
          PRPulseIgnoreKey.make(repositoryID: snapshot.repositoryID, number: $0.number)
        }
      )
      state.$prPulseIgnoredPRKeys.withLock { keys in
        keys.removeAll {
          PRPulseIgnoreKey.belongs($0, to: snapshot.repositoryID) && !live.contains($0)
        }
      }
    }
    return .none
  }

  func reducePRPulseFetchFailed(state: inout State, repositoryID: String) -> Effect<Action> {
    state.prPulseInFlight.remove(repositoryID)
    state.prPulseFailureAt[repositoryID] = date.now
    return .none
  }

  func reducePRPulseIgnoreToggled(
    state: inout State,
    repositoryID: String,
    number: Int
  ) -> Effect<Action> {
    let key = PRPulseIgnoreKey.make(repositoryID: repositoryID, number: number)
    state.$prPulseIgnoredPRKeys.withLock { keys in
      if let index = keys.firstIndex(of: key) {
        keys.remove(at: index)
      } else {
        keys.append(key)
      }
    }
    return .none
  }

  func reducePRPulseSessionRequested(
    state: inout State,
    repositoryID: String,
    number: Int,
    repositories: [Repository]
  ) -> Effect<Action> {
    guard let snapshot = state.prPulseSnapshots[repositoryID],
      let pullRequest = snapshot.pullRequests.first(where: { $0.number == number }),
      let coordinates = PRPulseReference.coordinates(slug: snapshot.slug),
      let refKey = PRPulseReference.dedupeKey(slug: snapshot.slug, number: number)
    else {
      return .none
    }
    if let session = state.sessions.first(where: { session in
      session.references.contains(where: { $0.dedupeKey == refKey })
    }) {
      state.newTerminalSheet = nil
      return .send(.focusSession(id: session.id))
    }
    let available = IdentifiedArray(uniqueElements: repositories)
    guard available[id: repositoryID] != nil else { return .none }
    let url = pullRequest.url.isEmpty
      ? "https://github.com/\(coordinates.owner)/\(coordinates.repo)/pull/\(number)"
      : pullRequest.url
    var sheet = NewTerminalFeature.State(
      availableRepositories: available,
      preferredRepositoryID: repositoryID
    )
    let parsed = ParsedPullRequestURL(
      url: url,
      owner: coordinates.owner,
      repo: coordinates.repo,
      number: number
    )
    let metadata = SupacoolPRMetadata(
      title: pullRequest.title,
      headRefName: pullRequest.headRefName,
      baseRefName: "",
      headRepositoryOwner: coordinates.owner,
      state: "OPEN",
      isDraft: pullRequest.isDraft
    )
    sheet.prompt = Self.prPulseSessionPrompt(url: url, pullRequest: pullRequest)
    sheet.pullRequestLookup = .resolved(
      PullRequestContext(
        parsed: parsed,
        metadata: metadata,
        matchedRepositoryID: repositoryID,
        isFork: false
      )
    )
    if pullRequest.headRefName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      sheet.selectedWorkspace = .newBranch(name: "")
      sheet.workspaceQuery = ""
    } else {
      sheet.selectedWorkspace = .existingBranch(name: pullRequest.headRefName)
      sheet.workspaceQuery = pullRequest.headRefName
    }
    state.focusedSessionID = nil
    state.newTerminalSheet = sheet
    return .none
  }

  // MARK: - PR Pulse fetch

  /// Fetch one repository's open-PR snapshot. Deliberately NOT
  /// `.cancellable` — like `prRefreshEffect` above, the in-flight set is
  /// only cleared by the terminal `_prPulseSnapshotLoaded` /
  /// `_prPulseFetchFailed` sends, so a cancellation would strand the
  /// repository in `prPulseInFlight` forever. The in-flight set itself
  /// already dedupes overlapping fetches.
  private func prPulseFetchEffect(
    target: PRPulseTarget,
    previous: RepoPullRequestSnapshot?
  ) -> Effect<Action> {
    .run { [gitClient, prMonitor] send in
      await send(._prPulseFetchStarted(repositoryID: target.repositoryID))
      do {
        // Race the whole fetch against a wall-clock timeout — same hung-
        // subprocess protection as `_refreshPRStatus` (gh wrappers can
        // stall indefinitely under proc-table pressure).
        let snapshot = try await withThrowingTaskGroup(of: RepoPullRequestSnapshot.self) { group in
          group.addTask {
            try await Self.fetchPulseSnapshot(
              target: target,
              previous: previous,
              gitClient: gitClient,
              prMonitor: prMonitor
            )
          }
          group.addTask {
            try await Task.sleep(for: Self.prPulseTimeout)
            throw PRRefreshTimeoutError()
          }
          defer { group.cancelAll() }
          guard let result = try await group.next() else {
            throw PRRefreshTimeoutError()
          }
          return result
        }
        await send(._prPulseSnapshotLoaded(snapshot: snapshot))
      } catch {
        boardLogger.warning("PR Pulse fetch failed for \(target.repositoryID): \(error)")
        await send(._prPulseFetchFailed(repositoryID: target.repositoryID))
      }
    }
  }

  /// One repo's snapshot: assigned `gh pr list` (single call, checks
  /// included), then Greptile scores for PRs whose `updatedAt` moved since
  /// the previous snapshot. Scores are reused on an unchanged `updatedAt` —
  /// any event that can change the score (push → re-review, new bot comment)
  /// also bumps the PR's `updatedAt`. Individual score lookups fail soft to
  /// nil; only the PR list itself failing fails the snapshot.
  nonisolated private static func fetchPulseSnapshot(
    target: PRPulseTarget,
    previous: RepoPullRequestSnapshot?,
    gitClient: GitClientDependency,
    prMonitor: PRMonitorClient
  ) async throws -> RepoPullRequestSnapshot {
    let rootURL = URL(fileURLWithPath: target.rootPath)
    guard let remote = await gitClient.remoteInfo(rootURL) else {
      // No GitHub remote — record an empty snapshot so the badge can
      // skip this repo instead of treating it as a fetch failure.
      return RepoPullRequestSnapshot(
        repositoryID: target.repositoryID,
        slug: "",
        pullRequests: [],
        fetchedAt: .distantPast
      )
    }
    var prs = try await prMonitor.fetchOpenPullRequests(remote.owner, remote.repo)
    let previousByNumber = Dictionary(
      (previous?.pullRequests ?? []).map { ($0.number, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    var needsScore: [Int] = []
    for index in prs.indices {
      if let cached = previousByNumber[prs[index].number],
        cached.updatedAt == prs[index].updatedAt
      {
        prs[index].greptileScore = cached.greptileScore
      } else {
        needsScore.append(index)
      }
    }
    if !needsScore.isEmpty {
      let owner = remote.owner
      let repo = remote.repo
      let numbersByIndex = needsScore.map { ($0, prs[$0].number) }
      let scores = await withTaskGroup(of: (Int, Int?).self) { group in
        var iter = numbersByIndex.makeIterator()
        var active = 0
        while active < Self.prPulseScoreConcurrencyCap, let (index, number) = iter.next() {
          group.addTask {
            (index, (try? await prMonitor.fetchGreptileScore(owner, repo, number)) ?? nil)
          }
          active += 1
        }
        var collected: [(Int, Int?)] = []
        while let result = await group.next() {
          collected.append(result)
          active -= 1
          if let (index, number) = iter.next() {
            group.addTask {
              (index, (try? await prMonitor.fetchGreptileScore(owner, repo, number)) ?? nil)
            }
            active += 1
          }
        }
        return collected
      }
      for (index, score) in scores {
        prs[index].greptileScore = score
      }
    }
    return RepoPullRequestSnapshot(
      repositoryID: target.repositoryID,
      slug: "\(remote.owner)/\(remote.repo)",
      pullRequests: prs,
      fetchedAt: .distantPast
    )
  }

  /// Targets eligible for a snapshot fetch: not in flight, last success
  /// older than `freshness`, and outside the failure cooldown.
  nonisolated fileprivate static func pickPRPulseDueTargets(
    targets: [PRPulseTarget],
    inFlight: Set<String>,
    successAt: [String: Date],
    failureAt: [String: Date],
    freshness: TimeInterval,
    now: Date
  ) -> [PRPulseTarget] {
    targets.filter { target in
      let id = target.repositoryID
      if inFlight.contains(id) { return false }
      if let success = successAt[id], now.timeIntervalSince(success) < freshness { return false }
      if let failure = failureAt[id],
        now.timeIntervalSince(failure) < prPulseFailureCooldown
      {
        return false
      }
      return true
    }
  }

  nonisolated static func prPulseSessionPrompt(
    url: String,
    pullRequest: MonitoredPullRequest
  ) -> String {
    if pullRequest.hasMergeConflict {
      return
        "Fix the merge conflicts on \(url). Update the branch against its base, resolve the "
        + "conflicts locally, run the relevant checks, and push the resolution."
    }
    return "Work on \(url)"
  }

  /// Merge two reference lists, deduping by `dedupeKey`. When
  /// `preferNewStates` is true, PR state from the new list wins; otherwise
  /// the first occurrence wins. Used to combine JSONL + prompt scans.
  nonisolated static func mergeReferences(
    _ primary: [SessionReference],
    with secondary: [SessionReference],
    preferNewStates: Bool = false
  ) -> [SessionReference] {
    var merged: [SessionReference] = []
    var seen = Set<String>()
    for ref in primary + secondary {
      let key = ref.dedupeKey
      if seen.insert(key).inserted {
        merged.append(ref)
      } else if preferNewStates,
        case .pullRequest(_, _, _, let newState, let newTitle) = ref,
        newState != nil,
        let idx = merged.firstIndex(where: { $0.dedupeKey == key }),
        case .pullRequest(let o, let r, let n, _, let oldTitle) = merged[idx]
      {
        merged[idx] = .pullRequest(
          owner: o, repo: r, number: n, state: newState, title: newTitle ?? oldTitle
        )
      }
    }
    return merged
  }

  nonisolated enum PRRefreshMode {
    /// Background scheduler: resolve unknown refs and keep active refs
    /// (OPEN/DRAFT) current. Terminal states are skipped to avoid
    /// polling ancient closed/merged PRs forever.
    case automatic
    /// User-visible refresh from a PR chip/popover. Still throttled, but
    /// includes CLOSED refs because the user explicitly asked to look at
    /// this session's PR state and closed PRs can be reopened.
    case visible
  }

  /// One PR eligible for a refresh fetch: picked by
  /// `pickPRRefreshCandidates`, consumed by `prRefreshEffect`.
  nonisolated struct PRRefreshCandidate: Equatable, Sendable {
    let refKey: String
    let owner: String
    let repo: String
    let number: Int
  }

  /// Collect unique PR refs eligible for refresh under the requested mode.
  /// Applies in-flight, failure-backoff, and success-cache throttles before
  /// returning the bounded worker batch.
  nonisolated static func pickPRRefreshCandidates(
    sessions: [AgentSession],
    sessionID: AgentSession.ID?,
    mode: PRRefreshMode,
    lastFailureAt: [String: Date],
    lastSuccessAt: [String: Date],
    jitter: [String: TimeInterval],
    inFlight: Set<String>,
    now: Date
  ) -> [PRRefreshCandidate] {
    var picked: [PRRefreshCandidate] = []
    var seenKeys = Set<String>()
    for session in sessions where sessionID == nil || session.id == sessionID {
      for ref in session.references {
        guard case .pullRequest(let owner, let repo, let number, let state, let title) = ref else {
          continue
        }
        guard shouldRefreshPRState(state, title: title, mode: mode) else { continue }
        let key = ref.dedupeKey
        if seenKeys.contains(key) { continue }
        if inFlight.contains(key) { continue }
        if let refreshedAt = lastSuccessAt[key],
          now.timeIntervalSince(refreshedAt) < Self.prStateCacheWindow
        {
          continue
        }
        if !shouldRetryPRRef(
          ref,
          lastFailureAt: lastFailureAt,
          jitter: jitter,
          now: now
        ) { continue }
        seenKeys.insert(key)
        picked.append(PRRefreshCandidate(refKey: key, owner: owner, repo: repo, number: number))
      }
    }
    return picked
  }

  nonisolated private static func shouldRefreshPRState(
    _ state: PRState?,
    title: String?,
    mode: PRRefreshMode
  ) -> Bool {
    // Refs persisted before titles existed have `title == nil` even in
    // terminal states. Fetch them once so the popover can show the title;
    // the success cache + the now-populated title stop further polling.
    if title == nil { return true }
    switch mode {
    case .automatic:
      return state == nil || state == .open || state == .draft
    case .visible:
      return state != .merged
    }
  }

  /// Returns a copy of `ref` with its PR state and title replaced.
  /// No-op for ticket refs.
  nonisolated static func updatingPRSnapshot(
    of ref: SessionReference,
    to snapshot: PullRequestSnapshot
  ) -> SessionReference {
    if case .pullRequest(let owner, let repo, let number, _, let title) = ref {
      // An empty fetched title still ends the nil-title backfill (store ""),
      // otherwise `shouldRefreshPRState` would re-poll this ref forever.
      let newTitle = snapshot.title.isEmpty ? (title ?? "") : snapshot.title
      return .pullRequest(
        owner: owner, repo: repo, number: number, state: snapshot.state, title: newTitle
      )
    }
    return ref
  }

  /// Loop guard: how many times auto-resume hands the same PR back to its
  /// agent before giving up and resurfacing it for the user.
  static let autoResumeMaxAttempts = 3

  /// What to do when a PR snapshot update lands. `.none` for a non-transition;
  /// `.notify` to fire the Phase-2 bounce notification; `.autoResume` to inject
  /// the fix-it prompt into the idle agent (Phase 3, opt-in).
  nonisolated enum PRReturnOutcome {
    case none
    case notify(Delegate)
    case autoResume(id: AgentSession.ID, prompt: String, fallback: Delegate)
  }

  /// Decides the outcome of a their-court→your-court PR transition. Pure so the
  /// gating (armed reason, agent idle, retry budget) is fully testable; the
  /// reducer feeds in the live settings and prior attempt count and applies
  /// the resulting state mutation + effect.
  nonisolated static func pullRequestReturnOutcome(
    refKey: String,
    previous: PullRequestSnapshot?,
    next: PullRequestSnapshot,
    sessions: [AgentSession],
    autoResume: AutoResumeSettings,
    priorAttempts: Int,
    maxAttempts: Int
  ) -> PRReturnOutcome {
    let after = PRBallState(snapshot: next)
    guard
      PRBallState.didReturnToCourt(from: previous.map { PRBallState(snapshot: $0) }, to: after),
      let reason = after.reasonLabel
    else { return .none }

    // refKey is "pr:owner/repo#number" — surface the number to the user.
    let prLabel = refKey.split(separator: "#").last.map { "PR #\($0)" } ?? "Pull request"
    let session = sessions.first { $0.references.contains { $0.dedupeKey == refKey } }

    func notification(suffix: String = "") -> Delegate {
      let title = session?.displayName ?? prLabel
      let body = (session?.displayName == nil ? reason : "\(prLabel): \(reason)") + suffix
      return .pullRequestReturnedToCourt(title: title, body: body)
    }

    // Auto-resume only mechanical reasons, only when armed, only for a session
    // that exists and is idle (never interrupt a working agent), and only
    // while the per-PR retry budget holds. `after.isAutoResumable` keeps the
    // human-judgment precedence: a changes-requested PR is never auto-resumed
    // even when a low Greptile score co-occurs. The prompt combines every
    // enabled condition present on the snapshot (CI + conflicts + score can
    // hit simultaneously); nil means all applicable cases are switched off.
    guard autoResume.enabled, after.isAutoResumable,
      let session, !session.lastKnownBusy,
      let prompt = autoResume.prompt(for: PRBallState.autoResumableConditions(snapshot: next))
    else {
      return .notify(notification())
    }
    if priorAttempts >= maxAttempts {
      return .notify(notification(suffix: " · auto-resumed \(maxAttempts)×, over to you"))
    }
    return .autoResume(id: session.id, prompt: prompt, fallback: notification())
  }

  /// Applies the retry-budget bookkeeping for a PR return outcome and returns
  /// the effect. Resets the budget once the PR recovers (ready to merge /
  /// merged); bumps it when we hand the PR back to its agent.
  static func applyPRReturnOutcome(
    _ outcome: PRReturnOutcome,
    refKey: String,
    next: PullRequestSnapshot,
    into state: inout State
  ) -> Effect<Action> {
    switch PRBallState(snapshot: next) {
    case .readyToMerge, .merged:
      state.autoResumeAttempts[refKey] = nil
    default:
      break
    }
    switch outcome {
    case .none:
      return .none
    case .notify(let delegate):
      return .send(.delegate(delegate))
    case .autoResume(let id, let prompt, let fallback):
      state.autoResumeAttempts[refKey, default: 0] += 1
      return .send(._autoResumePRReturn(id: id, prompt: prompt, fallback: fallback))
    }
  }

  /// True iff `ref` is a PR reference that hasn't failed within the
  /// `prRefreshFailureCooldown` window. Non-PR refs return false (the
  /// callers already filter to PRs upstream; this is defensive).
  nonisolated fileprivate static func shouldRetryPRRef(
    _ ref: SessionReference,
    lastFailureAt: [String: Date],
    jitter: [String: TimeInterval] = [:],
    now: Date
  ) -> Bool {
    guard case .pullRequest = ref else { return false }
    guard let failedAt = lastFailureAt[ref.dedupeKey] else { return true }
    let perRefJitter = jitter[ref.dedupeKey] ?? 0
    return now.timeIntervalSince(failedAt)
      >= Self.prRefreshFailureCooldown + perRefJitter
  }

  /// Worker for the bounded-concurrency PR-refresh tick. Races the
  /// `gh pr view` call (plus the Greptile-score lookup when the PR's
  /// `updatedAt` moved) against `prRefreshTimeout` and dispatches the
  /// appropriate action (`_prStateFanout` on success,
  /// `_prRefreshFailed` on failure or timeout). Pulled out as a
  /// `nonisolated static` so the `TaskGroup` workers in
  /// `_runPRRefreshTick` can `await` it without crossing the
  /// `@MainActor` boundary that the reducer is on.
  nonisolated static func fetchPRWithTimeout(
    refKey: String,
    owner: String,
    repo: String,
    number: Int,
    previous: PullRequestSnapshot?,
    githubCLI: GithubCLIClient,
    prMonitor: PRMonitorClient,
    clock: any Clock<Duration>,
    send: Send<Action>
  ) async {
    do {
      let snapshot = try await withThrowingTaskGroup(of: PullRequestSnapshot.self) { group in
        group.addTask {
          var snapshot = try await githubCLI.viewPullRequest(owner, repo, number)
          // Same score-reuse policy as PR Pulse: any event that can
          // change the score (push → re-review, new bot comment) also
          // bumps `updatedAt`. The score lookup fails soft to nil —
          // only the PR fetch itself failing fails the refresh.
          if Self.canReuseGreptileScore(previous: previous, updatedAt: snapshot.updatedAt) {
            snapshot.greptileScore = previous?.greptileScore
          } else {
            snapshot.greptileScore =
              (try? await prMonitor.fetchGreptileScore(owner, repo, number)) ?? nil
          }
          return snapshot
        }
        group.addTask {
          try await clock.sleep(for: Self.prRefreshTimeout)
          throw PRRefreshTimeoutError()
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else {
          throw PRRefreshTimeoutError()
        }
        return result
      }
      await send(._prStateFanout(refKey: refKey, snapshot: snapshot))
    } catch {
      boardLogger.warning(
        "PR refresh tick failed for \(owner)/\(repo)#\(number): \(error)"
      )
      await send(._prRefreshFailed(refKey: refKey))
    }
  }

  /// The previous snapshot's Greptile score is still valid iff the PR's
  /// `updatedAt` hasn't moved. Missing timestamps (older `gh`, first
  /// fetch) always refetch. Internal (not fileprivate) for the tests.
  nonisolated static func canReuseGreptileScore(
    previous: PullRequestSnapshot?,
    updatedAt: Date?
  ) -> Bool {
    guard let previousUpdatedAt = previous?.updatedAt, let updatedAt else { return false }
    return previousUpdatedAt == updatedAt
  }
}

/// Cancel ID for the global PR-refresh scheduler loop. There's only
/// ever one of these per app lifetime; `cancelInFlight: true` on
/// `_startPRRefresher` makes re-dispatching idempotent.
private nonisolated struct PRRefresherCancelID: Hashable, Sendable {}

/// Cancellation handle for the PR Pulse periodic ticker (the loop only —
/// individual snapshot fetches are deliberately not cancellable, see
/// `prPulseFetchEffect`).
private nonisolated struct PRPulseTickerCancelID: Hashable, Sendable {}
