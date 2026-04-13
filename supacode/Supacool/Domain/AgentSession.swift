import Foundation

/// A persistent agent-driven terminal session: one PTY inside a tab, running
/// claude-code or codex in interactive mode with an initial prompt.
///
/// Each session shows up as a card on the board. Status (in-progress / waiting
/// on me) is DERIVED at render time from the underlying terminal's agent-busy
/// signal — not stored here. What IS stored is the identity of the session,
/// its backing directory, and a lightweight flag that records whether it's
/// ever gone busy-then-idle (so we can tell "just created" apart from
/// "finished and waiting").
nonisolated struct AgentSession: Identifiable, Hashable, Codable, Sendable {
  /// Stable session identity. Also used as the Ghostty tab ID so the
  /// underlying `WorktreeTerminalState` tab is addressable by session ID.
  let id: UUID

  /// The registered repo this session belongs to (its `Repository.ID`,
  /// which is the repo root path).
  let repositoryID: String

  /// The workspace backing this session — either the repo root (directory
  /// mode) or a git worktree path. Matches `Worktree.ID` in the existing
  /// `WorktreeTerminalManager` states dictionary.
  let worktreeID: String

  let agent: AgentType

  /// What the user typed when creating the session. We keep this verbatim
  /// so "rerun" can replay it after a relaunch.
  let initialPrompt: String

  /// Human-readable card title. Defaults to a derivation of `initialPrompt`;
  /// user can rename.
  var displayName: String

  let createdAt: Date
  var lastActivityAt: Date

  /// Becomes true the first time the session transitions busy → idle. Used
  /// to distinguish "just spawned, first prompt still running" (stays in
  /// In Progress) from "agent finished, waiting on me" (moves to Waiting on Me).
  var hasCompletedAtLeastOnce: Bool

  init(
    id: UUID = UUID(),
    repositoryID: String,
    worktreeID: String,
    agent: AgentType,
    initialPrompt: String,
    displayName: String? = nil,
    createdAt: Date = Date(),
    lastActivityAt: Date = Date(),
    hasCompletedAtLeastOnce: Bool = false
  ) {
    self.id = id
    self.repositoryID = repositoryID
    self.worktreeID = worktreeID
    self.agent = agent
    self.initialPrompt = initialPrompt
    self.displayName = displayName ?? Self.deriveDisplayName(from: initialPrompt, fallbackID: id)
    self.createdAt = createdAt
    self.lastActivityAt = lastActivityAt
    self.hasCompletedAtLeastOnce = hasCompletedAtLeastOnce
  }

  /// Pulls the first ~5 meaningful words from the prompt, title-cases them,
  /// and truncates to a short label. Falls back to "Session <short-id>".
  nonisolated static func deriveDisplayName(from prompt: String, fallbackID: UUID) -> String {
    let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return "Session " + String(fallbackID.uuidString.prefix(8))
    }
    // Split on whitespace + punctuation, drop empties, take the first 5.
    let words = trimmed
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "_" })
      .prefix(5)
      .map(String.init)
    guard !words.isEmpty else {
      return "Session " + String(fallbackID.uuidString.prefix(8))
    }
    let candidate = words.joined(separator: " ")
    // Cap overall length so narrow cards don't explode.
    return String(candidate.prefix(60))
  }
}
