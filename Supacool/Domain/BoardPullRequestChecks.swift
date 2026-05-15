import Foundation

/// Board-level interpretation of PR checks. Pending or expected checks mean
/// the session is idle because CI is running, not because it needs the user.
nonisolated enum BoardPullRequestChecks {
  static func isWaiting(_ pullRequest: GithubPullRequest?) -> Bool {
    guard let pullRequest, pullRequest.state.uppercased() == "OPEN" else { return false }
    guard let checks = pullRequest.statusCheckRollup?.checks else { return false }
    return isWaiting(checks: checks)
  }

  static func isWaiting(checks: [GithubPullRequestStatusCheck]) -> Bool {
    guard !checks.isEmpty else { return false }

    var hasPendingCheck = false
    for check in checks {
      switch check.checkState {
      case .failure:
        // Failed checks are actionable, so let the normal idle classifier
        // route the card to Waiting on Me.
        return false
      case .inProgress, .expected:
        hasPendingCheck = true
      case .success, .skipped:
        continue
      }
    }
    return hasPendingCheck
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
