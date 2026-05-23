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
    guard let checks = pullRequest.statusCheckRollup?.checks else { return false }
    return isWaiting(checks: checks)
  }

  /// Broader predicate used by board classification: OPEN, non-draft, and
  /// either CI checks pending OR reviewers haven't acted yet
  /// (`reviewDecision == "REVIEW_REQUIRED"`). Approved / changes-requested
  /// PRs flip back to Waiting on Me — the user owns the next move.
  static func isWaitingExternal(_ pullRequest: GithubPullRequest?) -> Bool {
    guard let pullRequest, pullRequest.state.uppercased() == "OPEN", !pullRequest.isDraft else {
      return false
    }
    if let checks = pullRequest.statusCheckRollup?.checks, isWaiting(checks: checks) {
      return true
    }
    return pullRequest.reviewDecision?.uppercased() == "REVIEW_REQUIRED"
  }

  /// A PR is "waiting for checks" iff at least one check is still
  /// `inProgress`/`expected`. Sibling failures don't bail early — the
  /// card stays in Checks Pending until CI fully settles, at which
  /// point `outcome` reports `.completed(allPassed:)` and the card
  /// flips to Waiting on Me with a red glow if anything failed.
  static func isWaiting(checks: [GithubPullRequestStatusCheck]) -> Bool {
    guard !checks.isEmpty else { return false }
    return checks.contains { check in
      switch check.checkState {
      case .inProgress, .expected: true
      case .success, .failure, .skipped: false
      }
    }
  }

  /// Outcome of an OPEN PR's status-check rollup. Used by the board to
  /// glow cards whose CI has just finished so the user notices them
  /// without having to read the chip.
  enum ChecksOutcome: Equatable {
    /// No PR, PR not OPEN, or no checks reported yet.
    case unknown
    /// At least one check still `inProgress` or `expected`.
    case pending
    /// Every check has reached a terminal state.
    case completed(allPassed: Bool)
  }

  static func outcome(_ pullRequest: GithubPullRequest?) -> ChecksOutcome {
    guard let pullRequest, pullRequest.state.uppercased() == "OPEN" else { return .unknown }
    guard let checks = pullRequest.statusCheckRollup?.checks else { return .unknown }
    return outcome(checks: checks)
  }

  static func outcome(checks: [GithubPullRequestStatusCheck]) -> ChecksOutcome {
    guard !checks.isEmpty else { return .unknown }
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
    return .completed(allPassed: !sawFailure)
  }
}
