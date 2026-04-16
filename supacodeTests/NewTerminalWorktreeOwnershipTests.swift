import Testing

@testable import Supacool

struct NewTerminalWorktreeOwnershipTests {
  @Test func newWorktreeSelectionsOwnTheirBackingWorktree() {
    #expect(
      NewTerminalFeature.shouldRemoveBackingWorktreeOnDelete(
        selection: .newBranch(name: "feat-x"),
        rerunOwnedWorktreeID: nil
      )
    )
    #expect(
      NewTerminalFeature.shouldRemoveBackingWorktreeOnDelete(
        selection: .existingBranch(name: "main"),
        rerunOwnedWorktreeID: nil
      )
    )
  }

  @Test func repoRootAndForeignExistingWorktreesDoNotOwnBackingWorktree() {
    #expect(
      !NewTerminalFeature.shouldRemoveBackingWorktreeOnDelete(
        selection: .repoRoot,
        rerunOwnedWorktreeID: nil
      )
    )
    #expect(
      !NewTerminalFeature.shouldRemoveBackingWorktreeOnDelete(
        selection: .existingWorktree(id: "/tmp/repo/wt-1"),
        rerunOwnedWorktreeID: nil
      )
    )
  }

  @Test func rerunPreservesOwnershipWhenTargetingSameExistingWorktree() {
    #expect(
      NewTerminalFeature.shouldRemoveBackingWorktreeOnDelete(
        selection: .existingWorktree(id: "/tmp/repo/wt-1"),
        rerunOwnedWorktreeID: "/tmp/repo/wt-1"
      )
    )
    #expect(
      !NewTerminalFeature.shouldRemoveBackingWorktreeOnDelete(
        selection: .existingWorktree(id: "/tmp/repo/wt-2"),
        rerunOwnedWorktreeID: "/tmp/repo/wt-1"
      )
    )
  }
}
