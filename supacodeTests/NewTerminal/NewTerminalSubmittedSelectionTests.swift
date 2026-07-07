import Testing

@testable import Supacool

struct NewTerminalSubmittedSelectionTests {
  // MARK: - Main scope is explicit

  @Test func repoRootAgentPromptStaysRepoRoot() {
    // Regression: the Scope picker said "Main", but submit-time code
    // silently promoted Main + agent + prompt into a generated worktree
    // branch. Prompts that started with pasted file paths then became
    // branches like `var/folders/...`, causing git-wt failures. Main must
    // mean repo root; SessionSpawner only does best-effort sync for that path.
    let result = NewTerminalFeature.resolveSubmittedSelection(
      selection: .repoRoot,
      agent: .claude,
      trimmedPrompt: "/var/folders/z5/screenshot.png\n\nwhat is causing the failure?",
      rerunOwnedWorktreeID: nil
    )
    #expect(result == .repoRoot)
  }

  @Test func repoRootShellPromptStaysRepoRoot() {
    let result = NewTerminalFeature.resolveSubmittedSelection(
      selection: .repoRoot,
      agent: nil,
      trimmedPrompt: "make test",
      rerunOwnedWorktreeID: nil
    )
    #expect(result == .repoRoot)
  }

  @Test func repoRootEmptyPromptStaysRepoRoot() {
    let result = NewTerminalFeature.resolveSubmittedSelection(
      selection: .repoRoot,
      agent: .claude,
      trimmedPrompt: "",
      rerunOwnedWorktreeID: nil
    )
    #expect(result == .repoRoot)
  }

  @Test func repoRootRerunStaysRepoRoot() {
    let result = NewTerminalFeature.resolveSubmittedSelection(
      selection: .repoRoot,
      agent: .claude,
      trimmedPrompt: "Fix CEN-6863",
      rerunOwnedWorktreeID: "/Users/jz/Projects/centrum_backend"
    )
    #expect(result == .repoRoot)
  }

  // MARK: - Explicit worktree selections are left untouched

  @Test func explicitNewBranchIsLeftAlone() {
    let result = NewTerminalFeature.resolveSubmittedSelection(
      selection: .newBranch(name: "feat-x"),
      agent: .claude,
      trimmedPrompt: "Implement feature X",
      rerunOwnedWorktreeID: nil
    )
    #expect(result == .newBranch(name: "feat-x"))
  }

  @Test func explicitExistingBranchIsLeftAlone() {
    let result = NewTerminalFeature.resolveSubmittedSelection(
      selection: .existingBranch(name: "main"),
      agent: .claude,
      trimmedPrompt: "Run tests",
      rerunOwnedWorktreeID: nil
    )
    #expect(result == .existingBranch(name: "main"))
  }

  @Test func explicitExistingWorktreeIsLeftAlone() {
    let result = NewTerminalFeature.resolveSubmittedSelection(
      selection: .existingWorktree(id: "/tmp/repo/wt-1"),
      agent: .claude,
      trimmedPrompt: "Continue work",
      rerunOwnedWorktreeID: nil
    )
    #expect(result == .existingWorktree(id: "/tmp/repo/wt-1"))
  }
}
