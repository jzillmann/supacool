import Foundation

/// Free-text matching for the board's toolbar search. Every whitespace-
/// separated term must hit at least one of the card's visible strings
/// (name, prompt, repo, worktree, agent, model) — so "auth centrum"
/// finds the auth session in the centrum repo and nothing else.
nonisolated enum BoardSessionSearch {
  /// Trims and lowercases the raw field text. Empty result = no filter.
  static func normalized(_ raw: String) -> String {
    raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  /// `query` must already be `normalized`; an empty query matches everything.
  static func matches(_ session: AgentSession, query: String) -> Bool {
    guard !query.isEmpty else { return true }
    let haystack = searchableText(for: session).joined(separator: "\n").lowercased()
    return query.split(whereSeparator: \.isWhitespace).allSatisfy { haystack.contains($0) }
  }

  static func searchableText(for session: AgentSession) -> [String] {
    var values = [
      session.displayName,
      session.initialPrompt,
      URL(fileURLWithPath: session.repositoryID).lastPathComponent,
      URL(fileURLWithPath: session.worktreeID).lastPathComponent,
      URL(fileURLWithPath: session.currentWorkspacePath).lastPathComponent,
      AgentType.displayName(for: session.agent),
    ]
    if let model = session.model { values.append(model) }
    return values
  }
}
