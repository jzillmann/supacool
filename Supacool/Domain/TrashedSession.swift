import Foundation

/// A session the user removed from the board. Held for `retentionWindow`
/// (3 days) as recoverable session metadata. New removals delete owned
/// backing worktree(s) immediately after the dirty-worktree preflight;
/// the cleanup metadata below is still honored for legacy trash entries
/// decoded from disk.
///
/// On restore: the `session` payload reanimates the original card. The
/// PTY isn't restored — the user picks Rerun / Resume to get a fresh
/// terminal, just like a detached session.
nonisolated struct TrashedSession: Identifiable, Hashable, Codable, Sendable {
  /// Stable identity = the original session's ID. Lets restore /
  /// permanent-delete address the right entry without a separate UUID.
  var id: AgentSession.ID { session.id }

  /// Frozen snapshot of the session at trash time.
  let session: AgentSession

  /// `Repository.ID` (= repo root path) the session belonged to.
  let repositoryID: String

  /// State-key worktree ID of the session at trash time. Equal to
  /// `repositoryID` for repo-root sessions (no actual worktree to clean).
  let worktreeID: String

  /// Whether the backing worktree should be deleted on permanent
  /// removal. New trash entries set this to false because cleanup is
  /// dispatched at removal time; legacy entries may still carry true.
  let deleteBackingWorktree: Bool

  /// Extra worktrees this session created during its lifetime (e.g. via
  /// the convert-to-worktree popover). New trash entries clean these at
  /// removal time; legacy entries may still clean them on permanent delete.
  let additionalWorktreeIDsToDelete: [String]

  /// When the user moved this session to the trash. The sweeper uses
  /// `now - trashedAt > retentionWindow` to find expired entries.
  let trashedAt: Date

  /// How long entries linger before the sweeper nukes them. 3 days is
  /// a "long enough to undo a mistake the next morning, short enough
  /// not to grow disk forever" compromise.
  static let retentionWindow: TimeInterval = 3 * 24 * 60 * 60

  /// Convenience: when this entry will be permanently deleted, given
  /// the current date.
  func expiresAt() -> Date {
    trashedAt.addingTimeInterval(Self.retentionWindow)
  }

  /// Convenience: whether this entry should be swept now.
  func isExpired(now: Date) -> Bool {
    now.timeIntervalSince(trashedAt) >= Self.retentionWindow
  }

  init(
    session: AgentSession,
    repositoryID: String,
    worktreeID: String,
    deleteBackingWorktree: Bool,
    additionalWorktreeIDsToDelete: [String] = [],
    trashedAt: Date
  ) {
    self.session = session
    self.repositoryID = repositoryID
    self.worktreeID = worktreeID
    self.deleteBackingWorktree = deleteBackingWorktree
    self.additionalWorktreeIDsToDelete = additionalWorktreeIDsToDelete
    self.trashedAt = trashedAt
  }

  // Forward-compatible Codable — convention documented in
  // docs/agent-guides/persistence.md.
  enum CodingKeys: String, CodingKey {
    case session, repositoryID, worktreeID
    case deleteBackingWorktree, additionalWorktreeIDsToDelete
    case trashedAt
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    session = try c.decode(AgentSession.self, forKey: .session)
    repositoryID = try c.decode(String.self, forKey: .repositoryID)
    worktreeID = try c.decode(String.self, forKey: .worktreeID)
    deleteBackingWorktree =
      try c.decodeIfPresent(Bool.self, forKey: .deleteBackingWorktree) ?? false
    additionalWorktreeIDsToDelete =
      try c.decodeIfPresent([String].self, forKey: .additionalWorktreeIDsToDelete) ?? []
    trashedAt = try c.decodeIfPresent(Date.self, forKey: .trashedAt) ?? Date()
  }
}
