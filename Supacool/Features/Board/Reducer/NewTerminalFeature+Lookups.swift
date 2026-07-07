import ComposableArchitecture
import Foundation

private nonisolated let newTerminalLogger = SupaLogger("Supacool.NewTerminal")

/// The PR-URL and Linear-ticket lookup handlers plus the Linear-derived
/// naming helpers, mechanically extracted from `NewTerminalFeature.swift`;
/// behavior identical.
extension NewTerminalFeature {
  // MARK: - PR URL handling

  /// Kick off (or cancel) a gh-backed PR lookup based on the current
  /// prompt content. Returns the effect that performs the lookup —
  /// mutating the sheet state inline on transitions keeps the side-effect
  /// flow readable.
  func handlePromptChange(
    state: inout State
  ) -> Effect<Action> {
    state.validationMessage = nil
    let prEffect = handlePullRequestPromptChange(state: &state)
    let linearEffect = handleLinearTicketPromptChange(state: &state)
    return .merge(prEffect, linearEffect)
  }

  private func handlePullRequestPromptChange(
    state: inout State
  ) -> Effect<Action> {
    let parsed = ParsedPullRequestURL.firstMatch(in: state.prompt)

    switch (parsed, state.pullRequestLookup) {
    case (nil, .idle):
      return .none
    case (nil, _):
      // URL was removed — reset PR state but leave the workspace/repo
      // the user's already configured. They may still want to submit.
      state.pullRequestLookup = .idle
      return .cancel(id: CancelID.pullRequestLookup)
    case (let parsed?, .fetching(let pending)) where pending == parsed:
      return .none
    case (let parsed?, .resolved(let context)) where context.parsed == parsed:
      return .none
    case (let parsed?, .failed(let failed, _)) where failed == parsed:
      // Same URL already failed once — don't thrash the API.
      return .none
    case (let parsed?, .dismissed(let dismissed)) where dismissed == parsed:
      // User dismissed this exact URL — stay dismissed until they edit
      // it to something different.
      return .none
    case (let parsed?, _):
      return startPullRequestLookup(state: &state, parsed: parsed)
    }
  }

  /// Detects a Linear ticket id in the prompt and kicks off a debounced
  /// background fetch to resolve its title. Cached results (positive or
  /// negative) short-circuit. Auto-fills the workspace branch field on
  /// success when the user hasn't manually edited it yet.
  private func handleLinearTicketPromptChange(
    state: inout State
  ) -> Effect<Action> {
    guard let ticketID = firstLinearTicketID(in: state.prompt)?.uppercased() else {
      // Ticket id removed. Drop any in-flight fetch. Evict transient
      // failures (network / no-key / cancelled) so a genuine re-paste
      // retries them — those weren't real "no such ticket" answers.
      // Genuine not-found entries stay cached so a typo doesn't re-hit
      // the API on every keystroke.
      state.pendingLinearTicketID = nil
      for id in state.linearTransientFailureIDs {
        state.linearTitleCache[id] = nil
        state.linearBranchNameCache[id] = nil
      }
      state.linearTransientFailureIDs.removeAll()
      state.linearLookupMessage = nil
      return .cancel(id: CancelID.linearTicketLookup)
    }
    if let cached = state.linearTitleCache[ticketID] {
      // Already resolved once this sheet. A positive title lets us
      // (re-)attempt the workspace auto-fill right now — this is what makes
      // a re-paste recover from an earlier fill that lost the binding
      // round-trip race, without a fresh network round-trip. An empty
      // entry is a genuine not-found; leave the field (and its note) alone.
      if cached.isEmpty {
        return .none
      }
      state.linearLookupMessage = nil
      return Self.maybeAutoFillWorkspaceQueryFromLinear(state: &state)
    }
    if state.pendingLinearTicketID == ticketID {
      // Same id already mid-flight — let it finish.
      return .none
    }
    return startLinearLookup(state: &state, ticketID: ticketID, debounce: true)
  }

  /// Kicks off the Linear title fetch for `ticketID` and owns the failure
  /// policy so the sheet's status chip behaves. Two things make the
  /// "Couldn't reach Linear" banner far rarer than the naive one-shot:
  ///
  ///  - **Cancellation is not failure.** When the effect is cancelled
  ///    (the user typed past this id, the sheet closed) the underlying
  ///    `URLSession` task throws `URLError.cancelled` — which is *not* a
  ///    Swift `CancellationError`, so the old `catch is CancellationError`
  ///    missed it and reported a bogus failure. Both are now swallowed.
  ///  - **Transient network errors auto-retry** a couple of times with a
  ///    short backoff before the banner ever appears. A single blip
  ///    self-heals silently.
  ///
  /// `debounce` is true for prompt-driven lookups (coalesce a typing
  /// storm) and false for an explicit Retry tap (act immediately).
  func startLinearLookup(
    state: inout State,
    ticketID: String,
    debounce: Bool
  ) -> Effect<Action> {
    state.pendingLinearTicketID = ticketID
    state.linearLookupMessage = nil
    return .run { [linearClient, clock] send in
      if debounce {
        // Tiny debounce so a typing storm doesn't fire one HTTP call per
        // keystroke once the id is fully formed (`CEN-`, `CEN-6`, …).
        // A plain `try await` here means cancellation propagates out as a
        // `CancellationError`, which TCA drops silently — exactly right.
        try await clock.sleep(for: .milliseconds(400))
      }
      let maxAttempts = 3
      var lastError: Error?
      for attempt in 1...maxAttempts {
        do {
          let naming = try await linearClient.fetchIssueNaming(ticketID)
          await send(.linearTicketTitleResolved(id: ticketID, naming: naming))
          return
        } catch is CancellationError {
          return
        } catch let error as URLError where error.code == .cancelled {
          // In-flight request torn down (id changed / sheet closed). Not a
          // failure — stay quiet and let the replacement lookup take over.
          return
        } catch {
          lastError = error
          // Only network hiccups are worth retrying; API-level errors
          // (auth, malformed response) won't change on a retry.
          guard error is URLError, attempt < maxAttempts else { break }
          try await clock.sleep(for: .milliseconds(400 * attempt))
        }
      }
      if let lastError {
        newTerminalLogger.warning(
          "Linear ticket lookup failed for \(ticketID): \(lastError.localizedDescription)"
        )
        await send(
          .linearTicketTitleFailed(id: ticketID, message: linearFailureMessage(lastError))
        )
      }
    }
    .cancellable(id: CancelID.linearTicketLookup, cancelInFlight: true)
  }

  /// If the prompt's first Linear ticket has a cached title and the user
  /// hasn't manually edited the workspace field, prefill it with a
  /// kebab-cased branch name derived from the title (`cen-6690-foo-bar`).
  /// Idempotent — returns `.none` when conditions aren't met.
  static func maybeAutoFillWorkspaceQueryFromLinear(
    state: inout State
  ) -> Effect<Action> {
    guard !state.workspaceQueryUserEdited else { return .none }
    guard let ticketID = firstLinearTicketID(in: state.prompt)?.uppercased() else {
      return .none
    }
    guard let title = state.linearTitleCache[ticketID], !title.isEmpty else {
      return .none
    }
    // PR-armed flows pin the workspace field; don't fight that.
    if case .resolved = state.pullRequestLookup {
      return .none
    }
    let branchName = branchNameFromLinear(
      ticketID: ticketID,
      title: title,
      linearBranchName: state.linearBranchNameCache[ticketID]
    )
    guard !branchName.isEmpty else { return .none }
    state.workspaceQuery = branchName
    state.previousWorkspaceQuery = branchName
    state.selectedWorkspace = .newBranch(name: branchName)
    return .none
  }

  private func startPullRequestLookup(
    state: inout State,
    parsed: ParsedPullRequestURL
  ) -> Effect<Action> {
    state.pullRequestLookup = .fetching(parsed)
    // Extract (id, rootURL) pairs synchronously while we're still on the
    // main actor. Repository's Identifiable conformance is main-actor
    // isolated; touching .id inside a nonisolated Task is a Swift 6 error.
    let repoCoordinates: [(String, URL)] = state.availableRepositories.map {
      ($0.id, $0.rootURL)
    }
    return .run { [gitClient, supacoolGithubPR] send in
      // Race the gh call and the repo-matching lookup in parallel — the
      // gh call is the slow one, repo matching is just a few git plumbing
      // invocations. This keeps time-to-banner tight.
      async let metadataTask = supacoolGithubPR.fetchMetadata(
        parsed.owner,
        parsed.repo,
        parsed.number
      )
      async let repoMatchTask = findMatchingRepositoryID(
        candidates: repoCoordinates,
        owner: parsed.owner,
        repo: parsed.repo,
        gitClient: gitClient
      )

      do {
        let metadata = try await metadataTask
        let matchedID = await repoMatchTask

        if metadata.headRepositoryOwner != parsed.owner {
          await send(
            .pullRequestLookupNotMatched(
              parsed: parsed,
              reason:
                "Fork PRs aren't auto-checked-out yet. "
                + "Run `gh pr checkout \(parsed.number)` in a normal terminal instead."
            )
          )
          return
        }
        guard let matchedID else {
          await send(
            .pullRequestLookupNotMatched(
              parsed: parsed,
              reason:
                "No configured repo matches \(parsed.owner)/\(parsed.repo). "
                + "Add it in Settings → Repositories first."
            )
          )
          return
        }

        let context = PullRequestContext(
          parsed: parsed,
          metadata: metadata,
          matchedRepositoryID: matchedID,
          isFork: false
        )
        await send(.pullRequestLookupResolved(context))
      } catch {
        newTerminalLogger.warning(
          "PR lookup failed for \(parsed.url): \(error.localizedDescription)"
        )
        // Surface the actual failure reason — the original generic
        // "is gh installed?" message masked plenty of unrelated causes
        // (JSON parse errors, network issues, auth scope mismatches).
        // Truncate to keep the banner readable; full text goes to the log.
        let raw = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = String(raw.prefix(160))
        await send(
          .pullRequestLookupFailed(
            parsed: parsed,
            message: "Couldn't fetch PR details: \(detail)"
          )
        )
      }
    }
    .cancellable(id: CancelID.pullRequestLookup, cancelInFlight: true)
  }

  /// Apply a resolved PR context to the sheet: pin the repo, pre-fill the
  /// workspace field with the PR's head branch, and queue a branch
  /// reload if the repo actually changed.
  func applyPullRequestResolution(
    state: inout State,
    context: PullRequestContext
  ) -> Effect<Action> {
    guard Self.shouldAcceptLookupOutcome(for: context.parsed, state: state) else {
      return .none
    }

    state.pullRequestLookup = .resolved(context)
    state.validationMessage = nil

    let repoChanged = state.selectedRepositoryID != context.matchedRepositoryID
    if repoChanged {
      state.selectedRepositoryID = context.matchedRepositoryID
      state.availableLocalBranches = []
      state.availableRemoteBranches = []
    }
    state.workspaceQuery = context.metadata.headRefName
    state.previousWorkspaceQuery = context.metadata.headRefName
    state.selectedWorkspace = .existingBranch(name: context.metadata.headRefName)

    return repoChanged ? .send(.task) : .none
  }

  /// Guard: reject lookup outcomes for a URL that's no longer the one
  /// the sheet is tracking (the user edited or removed it mid-flight).
  static func shouldAcceptLookupOutcome(
    for parsed: ParsedPullRequestURL,
    state: State
  ) -> Bool {
    switch state.pullRequestLookup {
    case .fetching(let pending): return pending == parsed
    case .idle, .resolved, .failed, .dismissed: return false
    }
  }
}

// MARK: - Linear-derived naming

/// Builds a kebab-case branch name from a Linear ticket id and its title:
/// `cen-6690-streamline-the-foobar-pipeline`. The ticket id is always
/// included as a prefix so a glance at `git branch` makes the link to
/// the ticket obvious. Reuses `sanitizeBranchName` so the slug rules
/// (40-char cap, no special characters) match the LLM-generated path.
nonisolated func branchNameFromLinearTitle(ticketID: String, title: String) -> String {
  let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmedTitle.isEmpty else {
    return sanitizeBranchName(ticketID)
  }
  return sanitizeBranchName("\(ticketID) \(trimmedTitle)")
}

/// The workspace branch name for a Linear ticket. Prefers Linear's OWN
/// suggested branch name (already owner-stripped by the caller) so the
/// branch matches what you'd get from Linear's "Copy git branch name" or
/// the CLI — honoring your workspace's configured slug format and Linear's
/// exact slug rules, with no local 40-char truncation. Falls back to the
/// title-derived slug when Linear didn't supply a name (empty string) or
/// it stripped to nothing.
nonisolated func branchNameFromLinear(
  ticketID: String,
  title: String,
  linearBranchName: String?
) -> String {
  if let linear = linearBranchName?.trimmingCharacters(in: .whitespacesAndNewlines),
    !linear.isEmpty
  {
    return linear
  }
  return branchNameFromLinearTitle(ticketID: ticketID, title: title)
}

/// Strips Linear's owner/team prefix from a suggested branch name, keeping
/// everything from the ticket identifier onward:
/// `johannes/cen-6690-streamline` → `cen-6690-streamline`. The identifier
/// is preserved (so Linear's branch↔issue auto-linking still fires). When
/// the identifier can't be located, falls back to dropping a single
/// leading `owner/` segment.
nonisolated func linearBranchNameStrippingOwner(_ raw: String, ticketID: String) -> String {
  let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else { return "" }
  if let range = trimmed.range(of: ticketID.lowercased()) {
    return String(trimmed[range.lowerBound...])
  }
  if let slash = trimmed.firstIndex(of: "/") {
    return String(trimmed[trimmed.index(after: slash)...])
  }
  return trimmed
}

/// Builds a card display name from a Linear ticket id and its title:
/// `CEN-6690 · Streamline the foobar pipeline`. Capped at 80 chars so a
/// pathological Linear title doesn't blow up the matrix card layout.
nonisolated func displayNameFromLinearTitle(ticketID: String, title: String) -> String {
  let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmedTitle.isEmpty else { return ticketID }
  let combined = "\(ticketID) · \(trimmedTitle)"
  return String(combined.prefix(80))
}

/// Turns a Linear lookup error into a short, user-facing chip message.
/// `LinearClientError` already carries good copy (auth / no key / not
/// found); network `URLError`s get a friendlier, retry-oriented phrasing
/// than the raw system description.
nonisolated func linearFailureMessage(_ error: Error) -> String {
  if let linearError = error as? LinearClientError {
    return linearError.errorDescription ?? "Linear lookup failed — retry?"
  }
  if let urlError = error as? URLError {
    switch urlError.code {
    case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
      return "No connection to Linear — check your network, then retry."
    case .timedOut:
      return "Linear timed out — retry?"
    default:
      return "Couldn't reach Linear — retry?"
    }
  }
  return "Couldn't reach Linear — retry?"
}

/// Find the first configured repository whose GitHub remote matches the
/// given owner/repo pair. Runs the `remoteInfo` probes in parallel so the
/// PR banner appears quickly even when the user has many repos
/// configured. Case-insensitive match — GitHub coerces casing anyway.
///
/// Takes plain tuples instead of `IdentifiedArrayOf<Repository>` because
/// Repository's Identifiable conformance is `@MainActor`-isolated and we
/// run inside a nonisolated Task here.
nonisolated func findMatchingRepositoryID(
  candidates: [(String, URL)],
  owner: String,
  repo: String,
  gitClient: GitClientDependency
) async -> String? {
  await withTaskGroup(of: (String, GithubRemoteInfo?).self) { group in
    for (id, rootURL) in candidates {
      group.addTask {
        (id, await gitClient.remoteInfo(rootURL))
      }
    }
    for await (id, info) in group {
      guard let info else { continue }
      if info.owner.caseInsensitiveCompare(owner) == .orderedSame
        && info.repo.caseInsensitiveCompare(repo) == .orderedSame
      {
        group.cancelAll()
        return id
      }
    }
    return nil
  }
}
