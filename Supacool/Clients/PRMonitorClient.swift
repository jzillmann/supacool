import ComposableArchitecture
import Foundation

private nonisolated let prMonitorLogger = SupaLogger("Supacool.PRMonitor")

/// Repo-wide PR monitoring for the board's PR Pulse badge. Two thin calls:
/// the open-PR list (one `gh pr list` round-trip, checks included) and the
/// Greptile confidence score (one `gh api …/comments` round-trip per PR —
/// the score lives in a bot comment, not in any PR field).
///
/// Follows `SupacoolGithubPRClient`'s shape: shell out to `gh` via a login
/// shell so PATH/auth just work; errors surface to the reducer which owns
/// cooldown/backoff policy.
struct PRMonitorClient: Sendable {
  var fetchOpenPullRequests:
    @Sendable (_ owner: String, _ repo: String) async throws -> [MonitoredPullRequest]
  var fetchGreptileScore:
    @Sendable (_ owner: String, _ repo: String, _ number: Int) async throws -> Int?
}

extension PRMonitorClient: DependencyKey {
  static let liveValue = live()

  static func live(shell: ShellClient = .liveValue) -> PRMonitorClient {
    PRMonitorClient(
      fetchOpenPullRequests: { owner, repo in
        let stdout = try await runGh(
          shell: shell,
          arguments: [
            "pr", "list",
            "--repo", "\(owner)/\(repo)",
            "--state", "open",
            "--limit", "50",
            "--json", "number,title,url,author,isDraft,headRefName,updatedAt,reviewDecision,statusCheckRollup",
          ]
        )
        return try decodeOpenPullRequests(stdout: stdout)
      },
      fetchGreptileScore: { owner, repo, number in
        let stdout = try await runGh(
          shell: shell,
          arguments: [
            "api", "repos/\(owner)/\(repo)/issues/\(number)/comments?per_page=100",
          ]
        )
        return try decodeGreptileScore(stdout: stdout)
      }
    )
  }

  static let testValue = PRMonitorClient(
    fetchOpenPullRequests: { _, _ in
      struct UnimplementedFetchOpenPullRequests: Error {}
      throw UnimplementedFetchOpenPullRequests()
    },
    fetchGreptileScore: { _, _, _ in
      struct UnimplementedFetchGreptileScore: Error {}
      throw UnimplementedFetchGreptileScore()
    }
  )
}

// MARK: - Shelling out

private nonisolated func runGh(shell: ShellClient, arguments: [String]) async throws -> String {
  let envURL = URL(fileURLWithPath: "/usr/bin/env")
  let ghArguments = ["gh"] + arguments
  do {
    return try await shell.runLogin(envURL, ghArguments, nil, log: false).stdout
  } catch {
    prMonitorLogger.warning("gh invocation failed: \(error.localizedDescription)")
    throw error
  }
}

// MARK: - JSON decoding

/// `gh pr list --json` entry. `statusCheckRollup` is a flat array whose
/// elements `GithubPullRequestStatusCheck` already knows how to decode
/// (it handles both the CheckRun and StatusContext shapes).
private nonisolated struct PRListEntry: Decodable {
  struct Author: Decodable {
    let login: String?
  }

  let number: Int
  let title: String
  let url: String
  let author: Author?
  let isDraft: Bool
  let headRefName: String
  let updatedAt: Date
  let reviewDecision: String?
  let statusCheckRollup: [GithubPullRequestStatusCheck]?
}

nonisolated func decodeOpenPullRequests(stdout: String) throws -> [MonitoredPullRequest] {
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  let entries = try decoder.decode([PRListEntry].self, from: Data(stdout.utf8))
  return entries.map { entry in
    let checks = entry.statusCheckRollup ?? []
    return MonitoredPullRequest(
      number: entry.number,
      title: entry.title,
      url: entry.url,
      author: entry.author?.login ?? "",
      isDraft: entry.isDraft,
      headRefName: entry.headRefName,
      updatedAt: entry.updatedAt,
      reviewDecision: entry.reviewDecision,
      checks: PullRequestCheckBreakdown(checks: checks),
      ciOutcome: BoardPullRequestChecks.outcome(checks: checks),
      greptileScore: nil
    )
  }
}

private nonisolated struct IssueComment: Decodable {
  struct User: Decodable {
    let login: String?
  }

  let user: User?
  let body: String?
}

nonisolated func decodeGreptileScore(stdout: String) throws -> Int? {
  let comments = try JSONDecoder().decode([IssueComment].self, from: Data(stdout.utf8))
  return GreptileScoreParser.score(
    fromComments: comments.map { (login: $0.user?.login ?? "", body: $0.body ?? "") }
  )
}
