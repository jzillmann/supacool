import Testing

@testable import Supacool

struct SessionSpawnerRepoRootGuardTests {
  // MARK: - nonPristineReason mapping

  @Test func dirtyTreeBecomesAgentBlockingReason() {
    // The motivating case: a previous session left files modified in
    // the repo root. The agent-spawn path has to refuse and surface
    // *why* so the user can clean up.
    let reason = SessionSpawner.nonPristineReason(.skippedDirtyTree)
    #expect(reason == "working tree has uncommitted changes")
  }

  @Test func offDefaultBranchBecomesAgentBlockingReason() {
    let reason = SessionSpawner.nonPristineReason(
      .skippedNotOnDefaultBranch(currentBranch: "feat-x", defaultBranch: "main")
    )
    #expect(reason == "checked out on 'feat-x' instead of 'main'")
  }

  // MARK: - Informational outcomes don't block

  @Test func syncedIsNotPristineFailure() {
    #expect(SessionSpawner.nonPristineReason(.synced(advancedBy: 0)) == nil)
    #expect(SessionSpawner.nonPristineReason(.synced(advancedBy: 5)) == nil)
  }

  @Test func missingDefaultBranchDoesNotBlock() {
    // Fresh clone with no origin/HEAD symref. The repo's perfectly
    // usable — we just have no authoritative target to FF onto. Don't
    // hold the spawn hostage to a config quirk.
    #expect(SessionSpawner.nonPristineReason(.skippedNoDefaultBranch) == nil)
  }

  @Test func fetchFailureDoesNotBlock() {
    // Offline / auth fail. The working copy is fine to spawn against;
    // we just couldn't refresh from origin.
    #expect(
      SessionSpawner.nonPristineReason(.skippedFetchFailed(message: "network down")) == nil
    )
  }

  @Test func nonFastForwardableDivergenceDoesNotBlock() {
    // The repo's diverged from origin/main. The user knows; that's
    // their concern, not the spawner's.
    #expect(
      SessionSpawner.nonPristineReason(
        .skippedFastForwardNotPossible(message: "diverged")
      ) == nil
    )
  }

  @Test func unknownFailureDoesNotBlock() {
    // Conservative: if the sync flow itself crashed for some other
    // reason, fall back to permissive — letting the user spawn beats
    // a confusing wall of error text for an unrelated git glitch.
    #expect(
      SessionSpawner.nonPristineReason(.failedUnknown(message: "git went sideways")) == nil
    )
  }

  // MARK: - Error description

  @Test func errorDescriptionExplainsRecourse() {
    let error = NewTerminalError.repoRootNotPristine(
      reason: "working tree has uncommitted changes"
    )
    let description = error.errorDescription ?? ""
    #expect(description.contains("working tree has uncommitted changes"))
    // The recovery hint matters as much as the reason — without it the
    // user is left guessing whether to clean the repo, pick a worktree,
    // or wait for something to settle on its own.
    #expect(description.contains("worktree"))
  }
}
