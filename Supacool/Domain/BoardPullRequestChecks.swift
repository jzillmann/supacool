import Foundation

/// Board-level interpretation of PR state. Either pending CI or an
/// unanswered review request means the session is idle because something
/// outside the agent (and outside the user) owns the next move.
nonisolated enum BoardPullRequestChecks {
  /// CI-only predicate — still drives the green/red completion glow via
  /// `outcome`. For the board's "Waiting on External" row use
  /// `isWaitingExternal` instead.
  static func isWaiting(_ pullRequest: GithubPullRequest?) -> Bool {
    guard let pullRequest, pullRequest.state.uppercased() == "OPEN" else { return false }
    guard let checks = pullRequest.statusCheckRollup?.checks else {
      return pullRequest.hasUnreportedRequiredChecks
    }
    return isWaiting(checks: checks, hasUnreportedRequiredChecks: pullRequest.hasUnreportedRequiredChecks)
  }

  /// Broader predicate used by board classification: OPEN, non-draft, and
  /// either CI checks pending OR reviewers haven't acted yet
  /// (`reviewDecision == "REVIEW_REQUIRED"`). Approved / changes-requested
  /// PRs flip back to Waiting on Me — the user owns the next move.
  static func isWaitingExternal(_ pullRequest: GithubPullRequest?) -> Bool {
    guard let pullRequest, pullRequest.state.uppercased() == "OPEN", !pullRequest.isDraft else {
      return false
    }
    if isWaiting(pullRequest) {
      return true
    }
    return pullRequest.reviewDecision?.uppercased() == "REVIEW_REQUIRED"
  }

  /// A PR is "waiting for checks" iff at least one check is still
  /// `inProgress`/`expected`, or GitHub says a required check hasn't
  /// reported at all (`hasUnreportedRequiredChecks`). Sibling failures
  /// don't bail early — the card stays in Checks Pending until CI fully
  /// settles, at which point `outcome` reports `.completed(allPassed:)`
  /// and the card flips to Waiting on Me with a red glow if anything failed.
  static func isWaiting(
    checks: [GithubPullRequestStatusCheck],
    hasUnreportedRequiredChecks: Bool = false
  ) -> Bool {
    if hasUnreportedRequiredChecks {
      return true
    }
    guard !checks.isEmpty else { return false }
    return checks.contains { check in
      switch check.checkState {
      case .inProgress, .expected: true
      case .success, .failure, .skipped: false
      }
    }
  }

  /// Whether GitHub is blocking the merge on a required check that isn't in
  /// the rollup at all.
  ///
  /// `statusCheckRollup` lists only checks that have *reported*. A required
  /// status context nobody has posted yet (github.com shows it as "Expected —
  /// Waiting for status to be reported") and a workflow run still queued are
  /// both absent from it, so a PR whose CI has not started reads as "every
  /// check passed". Seen on `centrumai/centrum_backend#5423`: the rollup held
  /// one green Greptile run while the required "PR Gate" context had never
  /// reported and the CI workflow sat queued — the chip showed a green
  /// checkmark on a PR github.com called blocked.
  ///
  /// `mergeStateStatus == "BLOCKED"` is the only signal GitHub gives for it,
  /// and it is ambiguous: a missing review blocks the merge the same way. So
  /// a review that is itself blocking, or a check that already failed, is
  /// taken as the explanation and this stays false — better to under-report
  /// than to hang a permanent clock on every PR awaiting a reviewer.
  static func hasUnreportedRequiredChecks(
    mergeStateStatus: String?,
    reviewDecision: String?,
    checks: [GithubPullRequestStatusCheck]
  ) -> Bool {
    guard mergeStateStatus?.uppercased() == "BLOCKED" else { return false }
    switch reviewDecision?.uppercased() {
    case "REVIEW_REQUIRED", "CHANGES_REQUESTED":
      return false
    default:
      break
    }
    return PullRequestCheckBreakdown(checks: checks).failed == 0
  }

  /// Outcome of an OPEN PR's status-check rollup. Used by the board to
  /// glow cards whose CI has just finished so the user notices them
  /// without having to read the chip.
  enum ChecksOutcome: Equatable {
    /// No PR, PR not OPEN, or no checks reported yet.
    case unknown
    /// At least one check still `inProgress` or `expected`, or a required
    /// check hasn't reported yet.
    case pending
    /// Every check has reached a terminal state.
    case completed(allPassed: Bool)
  }

  static func outcome(_ pullRequest: GithubPullRequest?) -> ChecksOutcome {
    guard let pullRequest, pullRequest.state.uppercased() == "OPEN" else { return .unknown }
    guard let checks = pullRequest.statusCheckRollup?.checks else {
      return pullRequest.hasUnreportedRequiredChecks ? .pending : .unknown
    }
    return outcome(
      checks: checks,
      hasUnreportedRequiredChecks: pullRequest.hasUnreportedRequiredChecks
    )
  }

  static func outcome(
    checks: [GithubPullRequestStatusCheck],
    hasUnreportedRequiredChecks: Bool = false
  ) -> ChecksOutcome {
    var sawFailure = false
    for check in checks {
      switch check.checkState {
      case .inProgress, .expected:
        return .pending
      case .failure:
        sawFailure = true
      case .success, .skipped:
        continue
      }
    }
    // A failure is a settled verdict — report it even while GitHub blocks the
    // merge for some other reason.
    if sawFailure {
      return .completed(allPassed: false)
    }
    if hasUnreportedRequiredChecks {
      return .pending
    }
    guard !checks.isEmpty else { return .unknown }
    return .completed(allPassed: true)
  }
}

extension GithubPullRequest {
  /// See `BoardPullRequestChecks.hasUnreportedRequiredChecks`.
  nonisolated var hasUnreportedRequiredChecks: Bool {
    BoardPullRequestChecks.hasUnreportedRequiredChecks(
      mergeStateStatus: mergeStateStatus,
      reviewDecision: reviewDecision,
      checks: statusCheckRollup?.checks ?? []
    )
  }
}

extension PullRequestSnapshot {
  /// See `BoardPullRequestChecks.hasUnreportedRequiredChecks`.
  nonisolated var hasUnreportedRequiredChecks: Bool {
    BoardPullRequestChecks.hasUnreportedRequiredChecks(
      mergeStateStatus: mergeStateStatus,
      reviewDecision: reviewDecision,
      checks: statusChecks
    )
  }

  /// CI outcome for this snapshot, including required checks GitHub hasn't
  /// received yet. Prefer this over `BoardPullRequestChecks.outcome(checks:)`
  /// wherever a snapshot is in hand.
  nonisolated var checksOutcome: BoardPullRequestChecks.ChecksOutcome {
    BoardPullRequestChecks.outcome(
      checks: statusChecks,
      hasUnreportedRequiredChecks: hasUnreportedRequiredChecks
    )
  }
}
