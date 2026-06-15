import Foundation

/// Repo-wide pull request monitoring ("PR Pulse"). Unlike
/// `SessionReference.pullRequest` — which tracks PRs a *session* mentioned —
/// these types describe open PRs that need the authenticated GitHub user's
/// attention — ones they authored or are assigned to — fetched via `gh pr
/// list`, so the toolbar badge can answer "how many PRs need my attention,
/// and how many are actually green?" without a trip to github.com.

/// A board repository the pulse scheduler should monitor. Captured from the
/// view layer (which owns the `Repository` list) and stored on
/// `BoardFeature.State`; deliberately tiny so equality checks in
/// `.task(id:)` stay cheap.
nonisolated struct PRPulseTarget: Equatable, Hashable, Sendable {
  let repositoryID: String
  /// Repository root path used for `git remote` resolution. Works for bare
  /// git-wt containers too — `git remote get-url` needs no checkout.
  let rootPath: String
}

/// One open pull request as seen by the monitor.
nonisolated struct MonitoredPullRequest: Equatable, Sendable, Identifiable {
  let number: Int
  let title: String
  let url: String
  let author: String
  let isDraft: Bool
  let headRefName: String
  let updatedAt: Date
  /// Raw gh value: "", "APPROVED", "CHANGES_REQUESTED", "REVIEW_REQUIRED".
  let reviewDecision: String?
  /// Individual status checks as reported by `gh pr list`. Kept raw so the
  /// popover can expand a per-check breakdown with links to each CI run.
  let statusChecks: [GithubPullRequestStatusCheck]
  /// Greptile bot confidence score (1...5), nil when the PR has no
  /// Greptile review (bot not installed, or review still running).
  var greptileScore: Int?

  var id: Int { number }

  var checks: PullRequestCheckBreakdown { PullRequestCheckBreakdown(checks: statusChecks) }
  var ciOutcome: BoardPullRequestChecks.ChecksOutcome {
    BoardPullRequestChecks.outcome(checks: statusChecks)
  }

  /// Checks ordered for display: failures first, then running, then the
  /// rest — the popover truncates nothing, but the interesting rows
  /// should not hide below 18 green ones.
  var statusChecksForDisplay: [GithubPullRequestStatusCheck] {
    func rank(_ check: GithubPullRequestStatusCheck) -> Int {
      switch check.checkState {
      case .failure: 0
      case .inProgress, .expected: 1
      case .success: 2
      case .skipped: 3
      }
    }
    return statusChecks.enumerated()
      .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
      .map(\.element)
  }

  /// Traffic-light classification driving the badge counts and row dots.
  enum Health: Equatable, Sendable {
    /// CI fully passed and Greptile (if present) says 5/5.
    case green
    /// CI failed, or Greptile scored below 5/5 — somebody should look.
    case red
    /// Checks still running.
    case pending
    /// Draft, or no signal at all (no checks, no review).
    case neutral
  }

  var health: Health {
    if case .completed(allPassed: false) = ciOutcome { return .red }
    if let greptileScore, greptileScore < 5 { return .red }
    switch ciOutcome {
    case .pending:
      return .pending
    case .completed:
      // allPassed == true (the failure case returned above).
      return isDraft ? .neutral : .green
    case .unknown:
      // No checks reported. A 5/5 Greptile review is still a green signal.
      if !isDraft, greptileScore == 5 { return .green }
      return .neutral
    }
  }
}

/// Stable identifier for "this user ignored this PR", used to hide a PR from
/// the pulse badge/popover and exclude it from the counts. Keyed by repository
/// plus PR number — GitHub never reuses a PR number within a repo, so a stale
/// key (PR since merged/closed) can never accidentally re-ignore a different
/// PR; it simply matches nothing.
nonisolated enum PRPulseIgnoreKey {
  static func make(repositoryID: String, number: Int) -> String {
    "\(repositoryID)#\(number)"
  }

  /// True when `key` belongs to `repositoryID`. The `#` delimiter keeps the
  /// prefix test unambiguous even when one repo id is a prefix of another.
  static func belongs(_ key: String, to repositoryID: String) -> Bool {
    key.hasPrefix("\(repositoryID)#")
  }
}

/// My open PRs of one repository (authored or assigned) plus the coordinates
/// they were fetched with. Kept in memory only — a relaunch refetches within
/// one tick.
nonisolated struct RepoPullRequestSnapshot: Equatable, Sendable {
  let repositoryID: String
  /// "owner/repo", empty when the repository has no GitHub remote.
  let slug: String
  var pullRequests: [MonitoredPullRequest]
  var fetchedAt: Date

  var hasGithubRemote: Bool { !slug.isEmpty }

  var greenCount: Int { pullRequests.count(where: { $0.health == .green }) }
  var redCount: Int { pullRequests.count(where: { $0.health == .red }) }
  var pendingCount: Int { pullRequests.count(where: { $0.health == .pending }) }
}

/// Extracts the Greptile confidence score from PR issue comments.
/// Greptile posts (and later edits) a single summary comment containing
/// `<h3>Confidence Score: N/5</h3>`.
nonisolated enum GreptileScoreParser {
  static let botLogin = "greptile-apps[bot]"

  /// Score from one comment body, or nil if it doesn't contain one.
  static func score(in body: String) -> Int? {
    let regex = /Confidence Score:\s*(\d+)\s*\/\s*5/.ignoresCase()
    guard let match = body.firstMatch(of: regex) else { return nil }
    return Int(match.output.1)
  }

  /// Score from a comment thread: last Greptile comment wins, since the
  /// bot re-reviews after new pushes.
  static func score(fromComments comments: [(login: String, body: String)]) -> Int? {
    comments
      .filter { $0.login == botLogin }
      .compactMap { score(in: $0.body) }
      .last
  }
}
