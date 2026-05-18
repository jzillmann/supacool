import Foundation

/// Board-level interpretation of PR checks. Pending or expected checks mean
/// the session is idle because CI is running, not because it needs the user.
nonisolated enum BoardPullRequestChecks {
  static func isWaiting(_ pullRequest: GithubPullRequest?) -> Bool {
    guard let pullRequest, pullRequest.state.uppercased() == "OPEN" else { return false }
    guard let checks = pullRequest.statusCheckRollup?.checks else { return false }
    return isWaiting(checks: checks)
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
