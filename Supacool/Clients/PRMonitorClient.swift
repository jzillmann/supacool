import ComposableArchitecture
import Foundation

/// Repo-wide PR monitoring for the board's PR Pulse badge. The open-PR list
/// is a *union* of two `gh pr list` round-trips — PRs you authored and PRs
/// assigned to you — because `gh pr list` ANDs its filters, so a single
/// `--author --assignee` query would return only PRs that are both. Most PRs
/// you open are never self-assigned, so filtering on assignee alone silently
/// dropped them from the badge. The Greptile confidence score is a further
/// `gh api …/comments` round-trip per PR (the score lives in a bot comment,
/// not in any PR field).
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
        // Union of "authored by me" and "assigned to me". `gh pr list` ANDs
        // its filters, so we can't ask for both in one call — we run two and
        // merge by PR number (a PR you authored *and* are assigned shows once).
        async let authored = fetchOpenList(shell: shell, owner: owner, repo: repo, filter: "--author")
        async let assigned = fetchOpenList(shell: shell, owner: owner, repo: repo, filter: "--assignee")
        return try await mergeByNumber(authored, assigned)
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

// MARK: - Open-PR list (union of author + assignee)

/// One `gh pr list` round-trip filtered to the current user via `filter`
/// (`--author` or `--assignee`), value always `@me`.
private nonisolated func fetchOpenList(
  shell: ShellClient,
  owner: String,
  repo: String,
  filter: String
) async throws -> [MonitoredPullRequest] {
  let stdout = try await runGh(
    shell: shell,
    arguments: [
      "pr", "list",
      "--repo", "\(owner)/\(repo)",
      "--state", "open",
      filter, "@me",
      "--limit", "50",
      "--json",
      "number,title,url,author,isDraft,headRefName,updatedAt,reviewDecision,"
        + "mergeable,mergeStateStatus,statusCheckRollup",
    ]
  )
  return try decodeOpenPullRequests(stdout: stdout)
}

/// Merge two PR lists, deduping by number while preserving first-seen order
/// (authored PRs lead, then any assigned-only PRs).
nonisolated func mergeByNumber(
  _ first: [MonitoredPullRequest],
  _ second: [MonitoredPullRequest]
) -> [MonitoredPullRequest] {
  var seen = Set<Int>()
  var merged: [MonitoredPullRequest] = []
  for pr in first + second where seen.insert(pr.number).inserted {
    merged.append(pr)
  }
  return merged
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
  let mergeable: String?
  let mergeStateStatus: String?
  let statusCheckRollup: [GithubPullRequestStatusCheck]?
}

nonisolated func decodeOpenPullRequests(stdout: String) throws -> [MonitoredPullRequest] {
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  let entries = try decoder.decode([PRListEntry].self, from: Data(stdout.utf8))
  return entries.map { entry in
    MonitoredPullRequest(
      number: entry.number,
      title: entry.title,
      url: entry.url,
      author: entry.author?.login ?? "",
      isDraft: entry.isDraft,
      headRefName: entry.headRefName,
      updatedAt: entry.updatedAt,
      reviewDecision: entry.reviewDecision,
      mergeable: entry.mergeable,
      mergeStateStatus: entry.mergeStateStatus,
      statusChecks: entry.statusCheckRollup ?? [],
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
