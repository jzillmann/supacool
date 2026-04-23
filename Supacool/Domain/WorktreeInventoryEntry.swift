import Foundation

/// A single worktree row for the "Manage Worktrees…" janitor sheet.
///
/// Combines ground-truth identity (path, branch, head) from
/// `git worktree list --porcelain` with lazily-measured metadata (size,
/// last-commit, dirty count, ahead/behind, diff stat). Status is derived
/// against the live session list via `classifyWorktreeInventory` and is
/// never persisted — the inventory is always rebuilt on demand.
///
/// Supacool-specific. Intentionally *not* Codable: every field that
/// survives across app relaunches lives on `AgentSession`; this struct
/// is UI-state only.
nonisolated struct WorktreeInventoryEntry: Identifiable, Equatable, Sendable {
  /// Absolute path to the worktree on disk. Matches the `Worktree.ID`
  /// convention used elsewhere in the codebase so the row's ID is
  /// directly swappable with the existing deletion plumbing.
  let id: String
  let name: String
  let branch: String?
  let head: String
  var status: Status

  /// Disk footprint in bytes. `nil` until `du -sk` returns; UI renders
  /// a placeholder while the per-row measurement streams in.
  var sizeBytes: UInt64?

  /// HEAD commit metadata. `nil` until `git log -1` returns.
  var lastCommit: LastCommit?

  /// Number of `git status --porcelain` lines. `nil` until git returns;
  /// non-zero upgrades `.orphan` → `.orphanDirty` in the UI.
  var uncommittedCount: Int?

  /// Commits ahead/behind the repo's default branch. `nil` until
  /// `git rev-list --left-right --count` returns.
  var aheadBehind: AheadBehind?

  /// Populated lazily when the user expands the row. `nil` until then.
  var diffStat: String?

  nonisolated enum Status: Equatable, Sendable {
    /// Attached to at least one live Supacool session.
    case owned(sessionID: UUID, displayName: String)
    /// No live session references this worktree; working tree clean.
    case orphan
    /// No live session references this worktree, but the working tree
    /// has local uncommitted changes. Flagged separately so the UI can
    /// warn before deletion.
    case orphanDirty
    /// The repo root itself — never a deletion candidate.
    case repoRoot
  }

  nonisolated struct LastCommit: Equatable, Sendable {
    let date: Date
    let shortHash: String
    let subject: String
  }

  nonisolated struct AheadBehind: Equatable, Sendable {
    let ahead: Int
    let behind: Int
  }

  /// True when the user can reclaim this worktree. Repo root and
  /// owned-by-a-live-session rows are always false.
  var isDeletionCandidate: Bool {
    switch status {
    case .owned, .repoRoot:
      return false
    case .orphan, .orphanDirty:
      return true
    }
  }

  init(
    id: String,
    name: String,
    branch: String?,
    head: String,
    status: Status,
    sizeBytes: UInt64? = nil,
    lastCommit: LastCommit? = nil,
    uncommittedCount: Int? = nil,
    aheadBehind: AheadBehind? = nil,
    diffStat: String? = nil
  ) {
    self.id = id
    self.name = name
    self.branch = branch
    self.head = head
    self.status = status
    self.sizeBytes = sizeBytes
    self.lastCommit = lastCommit
    self.uncommittedCount = uncommittedCount
    self.aheadBehind = aheadBehind
    self.diffStat = diffStat
  }
}
