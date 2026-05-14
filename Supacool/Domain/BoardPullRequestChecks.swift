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
}
