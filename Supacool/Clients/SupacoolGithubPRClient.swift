import ComposableArchitecture
import Foundation

private nonisolated let prClientLogger = SupaLogger("Supacool.GithubPR")

/// Minimal Supacool-owned wrapper around `gh pr view` that returns enough
/// metadata to drive the "create session from a pasted PR URL" flow in
/// the New Terminal sheet. Upstream's `GithubCLIClient.viewPullRequest`
/// only exposes open/merged/closed state; we also need head + base refs
/// and the head repository's owner (so we can detect fork PRs).
///
/// Supacool-specific — lives under `Supacool/` rather than replacing upstream's `GithubCLIClient`.
struct SupacoolGithubPRClient: Sendable {
  var fetchMetadata:
    @Sendable (_ owner: String, _ repo: String, _ number: Int) async throws -> SupacoolPRMetadata
}

nonisolated struct SupacoolPRMetadata: Equatable, Sendable {
  let title: String
  let headRefName: String
  let baseRefName: String
  /// Owner of the head repository. For fork PRs this differs from the
  /// base-repo owner that was passed in; we use this to warn the user
  /// that v1 doesn't auto-check-out cross-fork branches.
  let headRepositoryOwner: String
  /// "OPEN" | "MERGED" | "CLOSED". Raw gh value, normalized on the view side.
  let state: String
  let isDraft: Bool
}

extension SupacoolGithubPRClient: DependencyKey {
  static let liveValue = live()

  static func live(shell: ShellClient = .liveValue) -> SupacoolGithubPRClient {
    SupacoolGithubPRClient(
      fetchMetadata: { owner, repo, number in
        let stdout = try await runGh(
          shell: shell,
          arguments: [
            "pr", "view", "\(number)",
            "--repo", "\(owner)/\(repo)",
            "--json", "title,headRefName,baseRefName,headRepositoryOwner,state,isDraft",
          ]
        )
        return try decodeMetadata(stdout: stdout, fallbackOwner: owner)
      }
    )
  }

  static let testValue = SupacoolGithubPRClient(
    fetchMetadata: { _, _, _ in
      struct UnimplementedFetchMetadata: Error {}
      throw UnimplementedFetchMetadata()
    }
  )
}

extension DependencyValues {
  var supacoolGithubPR: SupacoolGithubPRClient {
    get { self[SupacoolGithubPRClient.self] }
    set { self[SupacoolGithubPRClient.self] = newValue }
  }
}

// MARK: - Shelling out

/// Run `gh` via a login shell so PATH / auth plugins are loaded. We use
/// `/usr/bin/env gh` rather than replicating upstream's executable resolver
/// — if `gh` isn't on PATH, the error is surfaced as a non-blocking warning
/// in the sheet, same as any other lookup failure.
private nonisolated func runGh(shell: ShellClient, arguments: [String]) async throws -> String {
  let envURL = URL(fileURLWithPath: "/usr/bin/env")
  let ghArguments = ["gh"] + arguments
  do {
    return try await shell.runLogin(envURL, ghArguments, nil, log: false).stdout
  } catch {
    prClientLogger.warning("gh invocation failed: \(error.localizedDescription)")
    throw error
  }
}

// MARK: - JSON decoding

private nonisolated struct PRViewOwner: Decodable {
  let login: String
}

private nonisolated struct PRViewResponse: Decodable {
  let title: String
  let headRefName: String
  let baseRefName: String
  let state: String
  let isDraft: Bool
  // `gh pr view --json headRepositoryOwner` returns `{id, login}`. We only
  // need `login`. Optional because deleted-fork PRs can omit it entirely.
  let headRepositoryOwner: PRViewOwner?
}

nonisolated func decodeMetadata(stdout: String, fallbackOwner: String) throws -> SupacoolPRMetadata {
  let decoded = try JSONDecoder().decode(PRViewResponse.self, from: Data(stdout.utf8))
  return SupacoolPRMetadata(
    title: decoded.title,
    headRefName: decoded.headRefName,
    baseRefName: decoded.baseRefName,
    headRepositoryOwner: decoded.headRepositoryOwner?.login ?? fallbackOwner,
    state: decoded.state,
    isDraft: decoded.isDraft
  )
}

// MARK: - PR URL parsing

/// Parsed coordinates of a GitHub pull request URL. Used both for
/// detection in the prompt field and for canonical dedup.
nonisolated struct ParsedPullRequestURL: Equatable, Hashable, Sendable {
  let url: String
  let owner: String
  let repo: String
  let number: Int

  /// Stable key for deduping detections across keystrokes.
  var dedupeKey: String { "\(owner)/\(repo)#\(number)" }

  /// Extract the first GitHub PR URL from a free-text blob, if any. Mirrors
  /// the regex used by `SessionReferenceScannerLive.scanText` so detection
  /// in the New Terminal sheet is consistent with chip extraction on the
  /// board card.
  static func firstMatch(in text: String) -> ParsedPullRequestURL? {
    guard !text.isEmpty else { return nil }
    let regex = /https:\/\/github\.com\/([\w.-]+)\/([\w.-]+)\/pull\/(\d+)/
    guard let match = text.firstMatch(of: regex) else { return nil }
    guard let number = Int(match.output.3) else { return nil }
    return ParsedPullRequestURL(
      url: String(match.output.0),
      owner: String(match.output.1),
      repo: String(match.output.2),
      number: number
    )
  }
}
