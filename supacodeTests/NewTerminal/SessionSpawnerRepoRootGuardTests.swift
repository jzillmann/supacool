import Testing

@testable import Supacool

struct SessionSpawnerRepoRootGuardTests {
  // MARK: - nonPristineReason mapping

  @Test func dirtyTreeBecomesAgentLogReason() {
    // A Main-scope agent spawn still proceeds on a dirty repo root, but
    // the spawner logs the inherited state so later trace audits can see
    // why the root was not fast-forwarded first.
    let reason = SessionSpawner.nonPristineReason(.skippedDirtyTree)
    #expect(reason == "working tree has uncommitted changes")
  }

  @Test func offDefaultBranchBecomesAgentLogReason() {
    let reason = SessionSpawner.nonPristineReason(
      .skippedNotOnDefaultBranch(currentBranch: "feat-x", defaultBranch: "main")
    )
    #expect(reason == "checked out on 'feat-x' instead of 'main'")
  }

  // MARK: - Informational outcomes do not need a warning

  @Test func syncedIsNotPristineFailure() {
    #expect(SessionSpawner.nonPristineReason(.synced(advancedBy: 0)) == nil)
    #expect(SessionSpawner.nonPristineReason(.synced(advancedBy: 5)) == nil)
  }

  @Test func missingDefaultBranchDoesNotBlock() {
    // Fresh clone with no origin/HEAD symref. The repo is usable; we just
    // have no authoritative target to fast-forward onto.
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
    // The repo diverged from origin/main. The user knows; that is their
    // concern, not something that should block an explicit Main spawn.
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
}
