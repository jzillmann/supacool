import Testing

@testable import Supacool

struct NewTerminalWorktreeOwnershipTests {
  @Test func everyWorktreeBackedSessionNukesItsWorktreeOnRemove() {
    // Policy (post-2026-04): any session that points at a worktree
    // owns it on remove, regardless of whether SessionSpawner created
    // the worktree or adopted an existing one. The
    // `sessionsUsingWorkspace` ref-count guard in BoardFeature still
    // protects shared worktrees from premature deletion.
    #expect(
      NewTerminalFeature.shouldRemoveBackingWorktreeOnDelete(
        selection: .newBranch(name: "feat-x")
      )
    )
    #expect(
      NewTerminalFeature.shouldRemoveBackingWorktreeOnDelete(
        selection: .existingBranch(name: "main")
      )
    )
    #expect(
      NewTerminalFeature.shouldRemoveBackingWorktreeOnDelete(
        selection: .existingWorktree(id: "/tmp/repo/wt-1")
      )
    )
  }

  @Test func repoRootSessionsNeverNukeAWorktree() {
    // Repo-root sessions don't have a worktree to clean up — the
    // session's worktreeID equals the repositoryID. The flag is
    // false for symmetry with that.
    #expect(
      !NewTerminalFeature.shouldRemoveBackingWorktreeOnDelete(
        selection: .repoRoot
      )
    )
  }
}
