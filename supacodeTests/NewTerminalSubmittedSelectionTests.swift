import Testing

@testable import Supacool

struct NewTerminalSubmittedSelectionTests {
  // MARK: - Promotion to .newBranch

  @Test func repoRootAgentPromptIsPromotedToNewBranchSlug() {
    // The motivating bug: empty workspace field + agent + prompt resolved
    // to `.repoRoot`, dropping the agent inside the bare repo and letting
    // it `git checkout -b` against whatever HEAD happened to be on. Submit
    // must promote to a `.newBranch` so the spawn lands in a fresh
    // worktree off origin/main.
    let result = NewTerminalFeature.resolveSubmittedSelection(
      selection: .repoRoot,
      agent: .claude,
      trimmedPrompt: "Fix CEN-6863",
      rerunOwnedWorktreeID: nil
    )
    #expect(result == .newBranch(name: "fix-cen-6863"))
  }

  @Test func repoRootEmptySlugFallsBackToTask() {
    // Pathological prompts (all-punctuation, exotic unicode) sanitize to
    // an empty string. A constant fallback keeps the substitution
    // deterministic; if it collides with an existing branch the
    // worktree-creation conflict alert handles recovery.
    let result = NewTerminalFeature.resolveSubmittedSelection(
      selection: .repoRoot,
      agent: .claude,
      trimmedPrompt: "!!! ???",
      rerunOwnedWorktreeID: nil
    )
    #expect(result == .newBranch(name: "task"))
  }

  // MARK: - Left untouched

  @Test func shellOnlyRepoRootIsLeftAlone() {
    // `.repoRoot` with no agent is a deliberate "open a shell at the repo
    // root" workflow. Don't conjure a worktree the user didn't ask for.
    let result = NewTerminalFeature.resolveSubmittedSelection(
      selection: .repoRoot,
      agent: nil,
      trimmedPrompt: "",
      rerunOwnedWorktreeID: nil
    )
    #expect(result == .repoRoot)
  }

  @Test func repoRootEmptyPromptIsLeftAlone() {
    // Agent selected but no prompt — the validation chain already
    // rejects this combo before submit. Defense in depth: don't promote.
    let result = NewTerminalFeature.resolveSubmittedSelection(
      selection: .repoRoot,
      agent: .claude,
      trimmedPrompt: "",
      rerunOwnedWorktreeID: nil
    )
    #expect(result == .repoRoot)
  }

  @Test func repoRootRerunIsLeftAlone() {
    // A rerun whose `.rerunOwnedWorktreeID` points at the repo root means
    // the source session deliberately ran there. Honor that choice rather
    // than silently routing the replay into a new worktree.
    let result = NewTerminalFeature.resolveSubmittedSelection(
      selection: .repoRoot,
      agent: .claude,
      trimmedPrompt: "Fix CEN-6863",
      rerunOwnedWorktreeID: "/Users/jz/Projects/centrum_backend"
    )
    #expect(result == .repoRoot)
  }

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
