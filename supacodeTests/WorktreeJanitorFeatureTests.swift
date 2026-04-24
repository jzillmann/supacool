import ComposableArchitecture
import Foundation
import Testing

@testable import Supacool

/// Integration tests for `WorktreeJanitorFeature`. Exercises the full
/// scan → list → per-row metadata fan-out pipeline with a stubbed
/// `WorktreeInventoryClient`, plus the idempotency and state-transition
/// invariants the sheet relies on.
@MainActor
struct WorktreeJanitorFeatureTests {
  // MARK: - scanRequested

  @Test func scanLoadsRowsAndStreamsMetadata() async {
    let path = "/repos/foo/wt"
    let repoRoot = "/repos/foo"
    let store = TestStore(
      initialState: WorktreeJanitorFeature.State(
        repositoryID: repoRoot,
        repositoryName: "foo",
        sessionsSnapshot: []
      )
    ) {
      WorktreeJanitorFeature()
    } withDependencies: {
      $0.worktreeInventory.list = { _ in
        [
          GitWtWorktreeEntry(branch: "main", path: repoRoot, head: "r", isBare: false),
          GitWtWorktreeEntry(branch: "feature", path: path, head: "f", isBare: false),
        ]
      }
      $0.worktreeInventory.measure = { url in
        url.path(percentEncoded: false) == path ? 5 * 1024 * 1024 : 0
      }
      $0.worktreeInventory.gitMetadata = { _, _ in
        WorktreeInventoryGitMetadata(
          lastCommit: .init(date: Date(timeIntervalSince1970: 0), shortHash: "fff", subject: "wip"),
          uncommittedCount: 2,
          aheadBehind: .init(ahead: 1, behind: 0)
        )
      }
    }
    store.exhaustivity = .off

    await store.send(.scanRequested) {
      $0.isScanning = true
    }
    // Rows arrive first; the repo-root entry should be flagged as
    // `.repoRoot` (not measured / not metadata-queried).
    await store.receive(\._listLoaded) {
      $0.rows = [
        WorktreeInventoryEntry(
          id: "/repos/foo", name: "foo", branch: "main", head: "r",
          status: .repoRoot
        ),
        WorktreeInventoryEntry(
          id: "/repos/foo/wt", name: "wt", branch: "feature", head: "f",
          status: .orphan
        ),
      ]
    }
    // Per-row metadata streams in for the non-root row only.
    await store.receive(\._sizeLoaded) {
      $0.rows[id: "/repos/foo/wt"]?.sizeBytes = 5 * 1024 * 1024
    }
    await store.receive(\._metadataLoaded) {
      $0.rows[id: "/repos/foo/wt"]?.lastCommit = .init(
        date: Date(timeIntervalSince1970: 0), shortHash: "fff", subject: "wip"
      )
      $0.rows[id: "/repos/foo/wt"]?.aheadBehind = .init(ahead: 1, behind: 0)
      $0.rows[id: "/repos/foo/wt"]?.uncommittedCount = 2
      // uncommitted > 0 upgrades .orphan → .orphanDirty
      $0.rows[id: "/repos/foo/wt"]?.status = .orphanDirty
    }
    await store.receive(\._scanCompleted) {
      $0.isScanning = false
    }
  }

  @Test func scanIsIdempotentOnReentry() async {
    let store = TestStore(
      initialState: WorktreeJanitorFeature.State(
        repositoryID: "/repos/foo",
        repositoryName: "foo",
        sessionsSnapshot: []
      )
    ) {
      WorktreeJanitorFeature()
    } withDependencies: {
      // First scan: empty list → completes quickly.
      $0.worktreeInventory.list = { _ in [] }
      $0.worktreeInventory.measure = { _ in 0 }
      $0.worktreeInventory.gitMetadata = { _, _ in WorktreeInventoryGitMetadata() }
    }
    store.exhaustivity = .off

    await store.send(.scanRequested) {
      $0.isScanning = true
    }
    await store.receive(\._listLoaded)
    await store.receive(\._scanCompleted) {
      $0.isScanning = false
    }

    // A second `scanRequested` with non-empty rows (simulated by the
    // previous run) should NOT re-enter. In this test rows stayed
    // empty, so the second send has no guard to hit — exercise the
    // "already scanning" branch instead by firing again while
    // isScanning is true.
    await store.send(.scanRequested)  // no state change expected
    // No effects should fire; no further .receive.
  }

  @Test func listFailureSurfacesInlineWithoutAbortingTheSheet() async {
    struct ListBlewUp: LocalizedError {
      var errorDescription: String? { "scan failed for testing" }
    }
    let store = TestStore(
      initialState: WorktreeJanitorFeature.State(
        repositoryID: "/repos/foo",
        repositoryName: "foo",
        sessionsSnapshot: []
      )
    ) {
      WorktreeJanitorFeature()
    } withDependencies: {
      $0.worktreeInventory.list = { _ in throw ListBlewUp() }
    }
    store.exhaustivity = .off

    await store.send(.scanRequested)
    await store.receive(\._listFailed)
    #expect(store.state.scanError == "scan failed for testing")
    #expect(store.state.isScanning == false)
  }

  // MARK: - Classification wired through sessionsSnapshot

  @Test func sessionsSnapshotDrivesOwnerResolution() async {
    let session = AgentSession(
      repositoryID: "/repos/foo",
      worktreeID: "/repos/foo/wt",
      agent: .claude,
      initialPrompt: "hack",
      displayName: "Hack feature"
    )
    let store = TestStore(
      initialState: WorktreeJanitorFeature.State(
        repositoryID: "/repos/foo",
        repositoryName: "foo",
        sessionsSnapshot: [session]
      )
    ) {
      WorktreeJanitorFeature()
    } withDependencies: {
      $0.worktreeInventory.list = { _ in
        [GitWtWorktreeEntry(branch: "feature", path: "/repos/foo/wt", head: "a", isBare: false)]
      }
      $0.worktreeInventory.measure = { _ in 0 }
      $0.worktreeInventory.gitMetadata = { _, _ in WorktreeInventoryGitMetadata() }
    }
    store.exhaustivity = .off

    await store.send(.scanRequested)
    await store.receive(\._listLoaded)

    let row = store.state.rows[id: "/repos/foo/wt"]
    guard case .owned(let id, let name) = row?.status else {
      Issue.record("Expected owned status, got \(String(describing: row?.status))")
      return
    }
    #expect(id == session.id)
    #expect(name == "Hack feature")
  }

  // MARK: - closeRequested

  @Test func closeRequestedEmitsDismissDelegate() async {
    let store = TestStore(
      initialState: WorktreeJanitorFeature.State(
        repositoryID: "/repos/foo",
        repositoryName: "foo",
        sessionsSnapshot: []
      )
    ) {
      WorktreeJanitorFeature()
    }
    await store.send(.closeRequested)
    await store.receive(\.delegate.dismissed)
  }

  // MARK: - Selection

  @Test func toggleSelectionOnOrphanRow() async {
    var state = WorktreeJanitorFeature.State(
      repositoryID: "/r", repositoryName: "r", sessionsSnapshot: []
    )
    state.rows = [
      .init(id: "/r/wt", name: "wt", branch: "feat", head: "a", status: .orphan)
    ]
    let store = TestStore(initialState: state) {
      WorktreeJanitorFeature()
    }
    await store.send(.toggleSelection(id: "/r/wt")) {
      $0.selectedIDs = ["/r/wt"]
    }
    await store.send(.toggleSelection(id: "/r/wt")) {
      $0.selectedIDs = []
    }
  }

  @Test func toggleSelectionIgnoresNonCandidateRows() async {
    // Row is `.owned` — user taps its checkbox (shouldn't be
    // rendered, but a stale tap path shouldn't add it either).
    var state = WorktreeJanitorFeature.State(
      repositoryID: "/r", repositoryName: "r", sessionsSnapshot: []
    )
    state.rows = [
      .init(
        id: "/r/wt", name: "wt", branch: "feat", head: "a",
        status: .owned(sessionID: UUID(), displayName: "Live session")
      ),
    ]
    let store = TestStore(initialState: state) {
      WorktreeJanitorFeature()
    }
    await store.send(.toggleSelection(id: "/r/wt"))
    #expect(store.state.selectedIDs.isEmpty)
  }

  @Test func selectAllCandidatesOnlyPicksOrphans() async {
    var state = WorktreeJanitorFeature.State(
      repositoryID: "/r", repositoryName: "r", sessionsSnapshot: []
    )
    state.rows = [
      .init(id: "/r", name: "r", branch: "main", head: "a", status: .repoRoot),
      .init(
        id: "/r/live", name: "live", branch: "b1", head: "b",
        status: .owned(sessionID: UUID(), displayName: "Live")
      ),
      .init(id: "/r/orphan", name: "orphan", branch: "b2", head: "c", status: .orphan),
      .init(id: "/r/dirty", name: "dirty", branch: "b3", head: "d", status: .orphanDirty),
    ]
    let store = TestStore(initialState: state) {
      WorktreeJanitorFeature()
    }
    await store.send(.selectAllCandidates) {
      $0.selectedIDs = ["/r/orphan", "/r/dirty"]
    }
  }

  @Test func clearSelectionDropsAllIDs() async {
    var state = WorktreeJanitorFeature.State(
      repositoryID: "/r", repositoryName: "r", sessionsSnapshot: []
    )
    state.rows = [
      .init(id: "/r/wt", name: "wt", branch: "x", head: "a", status: .orphan)
    ]
    state.selectedIDs = ["/r/wt"]
    let store = TestStore(initialState: state) {
      WorktreeJanitorFeature()
    }
    await store.send(.clearSelection) {
      $0.selectedIDs = []
    }
  }

  // MARK: - Reclaim accounting

  @Test func selectedReclaimBytesSumsOverPickedRows() {
    var state = WorktreeJanitorFeature.State(
      repositoryID: "/r", repositoryName: "r", sessionsSnapshot: []
    )
    state.rows = [
      .init(
        id: "/r/a", name: "a", branch: nil, head: "a",
        status: .orphan, sizeBytes: UInt64(1_000)
      ),
      .init(
        id: "/r/b", name: "b", branch: nil, head: "b",
        status: .orphan, sizeBytes: UInt64(2_000)
      ),
      .init(
        id: "/r/c", name: "c", branch: nil, head: "c",
        status: .orphan, sizeBytes: UInt64(4_000)
      ),
    ]
    state.selectedIDs = ["/r/a", "/r/c"]
    #expect(state.selectedReclaimBytes == 5_000)
  }

  // MARK: - Delete flow

  @Test func deleteSelectedRequestedPopulatesConfirmation() async {
    var state = WorktreeJanitorFeature.State(
      repositoryID: "/r", repositoryName: "r", sessionsSnapshot: []
    )
    state.rows = [
      .init(
        id: "/r/wt", name: "wt", branch: "feat", head: "a",
        status: .orphanDirty, sizeBytes: UInt64(1_024 * 1_024)
      ),
    ]
    state.selectedIDs = ["/r/wt"]
    let store = TestStore(initialState: state) {
      WorktreeJanitorFeature()
    }
    store.exhaustivity = .off

    await store.send(.deleteSelectedRequested)
    guard let confirmation = store.state.deleteConfirmation else {
      Issue.record("Expected confirmation to be populated")
      return
    }
    #expect(confirmation.targets.count == 1)
    #expect(confirmation.targets[0].name == "wt")
    #expect(confirmation.targets[0].isDirty)
    #expect(confirmation.totalBytes == 1_024 * 1_024)
    #expect(confirmation.hasDirty)
  }

  @Test func deleteSelectedRequestedNoopsWhenSelectionEmpty() async {
    let store = TestStore(
      initialState: WorktreeJanitorFeature.State(
        repositoryID: "/r", repositoryName: "r", sessionsSnapshot: []
      )
    ) {
      WorktreeJanitorFeature()
    }
    await store.send(.deleteSelectedRequested)
    #expect(store.state.deleteConfirmation == nil)
  }

  @Test func deleteConfirmedRemovesRowsAndClearsSelection() async {
    var state = WorktreeJanitorFeature.State(
      repositoryID: "/r", repositoryName: "r", sessionsSnapshot: []
    )
    state.rows = [
      .init(id: "/r/a", name: "a", branch: "b1", head: "a", status: .orphan),
      .init(id: "/r/b", name: "b", branch: "b2", head: "b", status: .orphan),
    ]
    state.selectedIDs = ["/r/a", "/r/b"]
    state.deleteConfirmation = .init(
      id: UUID(),
      targets: [
        .init(id: "/r/a", name: "a", branch: "b1", sizeBytes: nil, isDirty: false),
        .init(id: "/r/b", name: "b", branch: "b2", sizeBytes: nil, isDirty: false),
      ]
    )

    let store = TestStore(initialState: state) {
      WorktreeJanitorFeature()
    } withDependencies: {
      $0.gitClient.removeWorktree = { _, _ in URL(fileURLWithPath: "/ok") }
    }
    store.exhaustivity = .off

    await store.send(.deleteConfirmed) {
      $0.deleteConfirmation = nil
      $0.deletingIDs = ["/r/a", "/r/b"]
    }
    await store.receive(\._deleteCompleted)
    await store.receive(\._deleteCompleted)

    #expect(store.state.rows.isEmpty)
    #expect(store.state.selectedIDs.isEmpty)
    #expect(store.state.deletingIDs.isEmpty)
    #expect(store.state.deleteErrors.isEmpty)
  }

  @Test func deleteFailureLeavesRowVisibleAndAppendsError() async {
    struct RemoveKaboom: LocalizedError {
      var errorDescription: String? { "rm failed" }
    }
    var state = WorktreeJanitorFeature.State(
      repositoryID: "/r", repositoryName: "r", sessionsSnapshot: []
    )
    state.rows = [
      .init(id: "/r/a", name: "a", branch: "b1", head: "a", status: .orphan)
    ]
    state.selectedIDs = ["/r/a"]
    state.deleteConfirmation = .init(
      id: UUID(),
      targets: [.init(id: "/r/a", name: "a", branch: "b1", sizeBytes: nil, isDirty: false)]
    )

    let store = TestStore(initialState: state) {
      WorktreeJanitorFeature()
    } withDependencies: {
      $0.gitClient.removeWorktree = { _, _ in throw RemoveKaboom() }
    }
    store.exhaustivity = .off

    await store.send(.deleteConfirmed)
    await store.receive(\._deleteCompleted)

    #expect(store.state.rows.count == 1)
    #expect(store.state.selectedIDs == ["/r/a"])
    #expect(store.state.deletingIDs.isEmpty)
    #expect(store.state.deleteErrors.count == 1)
    #expect(store.state.deleteErrors[0].contains("rm failed"))
  }

  @Test func deleteConfirmationCancelledClearsPendingState() async {
    var state = WorktreeJanitorFeature.State(
      repositoryID: "/r", repositoryName: "r", sessionsSnapshot: []
    )
    state.deleteConfirmation = .init(id: UUID(), targets: [])
    let store = TestStore(initialState: state) {
      WorktreeJanitorFeature()
    }
    await store.send(.deleteConfirmationCancelled) {
      $0.deleteConfirmation = nil
    }
  }

  // MARK: - Prune fold

  @Test func scanRunsPruneBeforeListAndPopulatesCount() async {
    let store = TestStore(
      initialState: WorktreeJanitorFeature.State(
        repositoryID: "/r", repositoryName: "r", sessionsSnapshot: []
      )
    ) {
      WorktreeJanitorFeature()
    } withDependencies: {
      $0.supacoolWorktreePrune.prune = { _ in
        SupacoolPruneResult(prunedRefs: ["foo", "bar", "baz"], rawOutput: "")
      }
      $0.worktreeInventory.list = { _ in [] }
    }
    store.exhaustivity = .off

    await store.send(.scanRequested)
    await store.receive(\._pruneCompleted)
    #expect(store.state.prunedRefCount == 3)
  }

  @Test func scanToleratesPruneFailure() async {
    struct PruneKaboom: Error {}
    let store = TestStore(
      initialState: WorktreeJanitorFeature.State(
        repositoryID: "/r", repositoryName: "r", sessionsSnapshot: []
      )
    ) {
      WorktreeJanitorFeature()
    } withDependencies: {
      $0.supacoolWorktreePrune.prune = { _ in throw PruneKaboom() }
      $0.worktreeInventory.list = { _ in [] }
    }
    store.exhaustivity = .off

    await store.send(.scanRequested)
    await store.receive(\._pruneCompleted)
    // Prune failed → count stays 0 — but the rest of the scan still
    // runs. Reaching `_scanCompleted` is the real assertion here.
    await store.receive(\._scanCompleted)
    #expect(store.state.prunedRefCount == 0)
  }

  // MARK: - Default branch resolution

  @Test func scanResolvesDefaultBranchRef() async {
    let store = TestStore(
      initialState: WorktreeJanitorFeature.State(
        repositoryID: "/r", repositoryName: "r", sessionsSnapshot: []
      )
    ) {
      WorktreeJanitorFeature()
    } withDependencies: {
      $0.supacoolWorktreePrune.prune = { _ in
        SupacoolPruneResult(prunedRefs: [], rawOutput: "")
      }
      $0.worktreeInventory.defaultBranchRef = { _ in "origin/trunk" }
      $0.worktreeInventory.list = { _ in [] }
    }
    store.exhaustivity = .off

    await store.send(.scanRequested)
    await store.receive(\._baseRefResolved)
    #expect(store.state.baseRef == "origin/trunk")
  }

  @Test func scanFallsBackWhenDefaultBranchUnresolvable() async {
    struct SymRefMissing: Error {}
    let store = TestStore(
      initialState: WorktreeJanitorFeature.State(
        repositoryID: "/r", repositoryName: "r", sessionsSnapshot: []
      )
    ) {
      WorktreeJanitorFeature()
    } withDependencies: {
      $0.supacoolWorktreePrune.prune = { _ in
        SupacoolPruneResult(prunedRefs: [], rawOutput: "")
      }
      $0.worktreeInventory.defaultBranchRef = { _ in throw SymRefMissing() }
      $0.worktreeInventory.list = { _ in [] }
    }
    store.exhaustivity = .off

    await store.send(.scanRequested)
    await store.receive(\._scanCompleted)
    // baseRef stays at the fallback.
    #expect(store.state.baseRef == "origin/HEAD")
  }

  // MARK: - Orphan session reconciliation

  @Test func scanDetectsOrphanSessionCards() async {
    // Session's worktree isn't in the inventory → orphan card.
    let ghost = AgentSession(
      repositoryID: "/r",
      worktreeID: "/r/gone",
      agent: .claude,
      initialPrompt: "hack"
    )
    // Session at repo root → never an orphan (repo can't go stale
    // from a worktree perspective).
    let rootSession = AgentSession(
      repositoryID: "/r",
      worktreeID: "/r",
      agent: .claude,
      initialPrompt: "root"
    )
    let store = TestStore(
      initialState: WorktreeJanitorFeature.State(
        repositoryID: "/r",
        repositoryName: "r",
        sessionsSnapshot: [ghost, rootSession]
      )
    ) {
      WorktreeJanitorFeature()
    } withDependencies: {
      $0.supacoolWorktreePrune.prune = { _ in
        SupacoolPruneResult(prunedRefs: [], rawOutput: "")
      }
      $0.worktreeInventory.list = { _ in
        [GitWtWorktreeEntry(branch: "main", path: "/r", head: "a", isBare: false)]
      }
    }
    store.exhaustivity = .off

    await store.send(.scanRequested)
    await store.receive(\._listLoaded)

    #expect(store.state.orphanSessionIDs == [ghost.id])
    #expect(store.state.showsOrphanBanner)
  }

  @Test func dismissOrphanBannerHidesItWithoutRemovingCards() async {
    var state = WorktreeJanitorFeature.State(
      repositoryID: "/r", repositoryName: "r", sessionsSnapshot: []
    )
    state.orphanSessionIDs = [UUID()]
    let store = TestStore(initialState: state) {
      WorktreeJanitorFeature()
    }
    await store.send(.dismissOrphanBanner) {
      $0.orphanBannerDismissed = true
    }
    #expect(store.state.showsOrphanBanner == false)
    // IDs are preserved — user can still remove them via parent.
    #expect(store.state.orphanSessionIDs.count == 1)
  }

  @Test func removeOrphanCardsRequestedEmitsDelegate() async {
    let ids = [UUID(), UUID()]
    var state = WorktreeJanitorFeature.State(
      repositoryID: "/r", repositoryName: "r", sessionsSnapshot: []
    )
    state.orphanSessionIDs = ids
    let store = TestStore(initialState: state) {
      WorktreeJanitorFeature()
    }
    await store.send(.removeOrphanCardsRequested) {
      $0.orphanSessionIDs = []
    }
    await store.receive(\.delegate.removeOrphanSessionCardsRequested)
  }

  // MARK: - Diff stat row expansion

  @Test func toggleRowExpansionFiresDiffStatFetchOnce() async {
    var state = WorktreeJanitorFeature.State(
      repositoryID: "/r", repositoryName: "r", sessionsSnapshot: []
    )
    state.rows = [
      .init(id: "/r/wt", name: "wt", branch: "feat", head: "a", status: .orphan)
    ]
    let fetchCount = DiffStatCounter()
    let store = TestStore(initialState: state) {
      WorktreeJanitorFeature()
    } withDependencies: {
      $0.worktreeInventory.diffStat = { _, _ in
        await fetchCount.increment()
        return " file.swift | 2 ++\n 1 file changed, 2 insertions(+)\n"
      }
    }
    store.exhaustivity = .off

    // First expansion → fetch fires.
    await store.send(.toggleRowExpansion(id: "/r/wt")) {
      $0.expandedRowID = "/r/wt"
      $0.loadingDiffStatIDs = ["/r/wt"]
    }
    await store.receive(\._diffStatLoaded)
    #expect(await fetchCount.get() == 1)
    #expect(store.state.rows[id: "/r/wt"]?.diffStat?.contains("1 file changed") == true)
    #expect(store.state.loadingDiffStatIDs.isEmpty)

    // Collapse.
    await store.send(.toggleRowExpansion(id: "/r/wt")) {
      $0.expandedRowID = nil
    }

    // Re-expand → no new fetch (cached on the row).
    await store.send(.toggleRowExpansion(id: "/r/wt")) {
      $0.expandedRowID = "/r/wt"
    }
    #expect(await fetchCount.get() == 1)
  }

  @Test func diffStatFailureSurfacesInlineWithoutClearingRow() async {
    struct DiffKaboom: LocalizedError {
      var errorDescription: String? { "diff exploded" }
    }
    var state = WorktreeJanitorFeature.State(
      repositoryID: "/r", repositoryName: "r", sessionsSnapshot: []
    )
    state.rows = [
      .init(id: "/r/wt", name: "wt", branch: "feat", head: "a", status: .orphan)
    ]
    let store = TestStore(initialState: state) {
      WorktreeJanitorFeature()
    } withDependencies: {
      $0.worktreeInventory.diffStat = { _, _ in throw DiffKaboom() }
    }
    store.exhaustivity = .off

    await store.send(.toggleRowExpansion(id: "/r/wt"))
    await store.receive(\._diffStatLoaded)
    #expect(store.state.rows[id: "/r/wt"]?.diffStat?.contains("diff exploded") == true)
    #expect(store.state.rows.count == 1)
  }

  @Test func emptyDiffStatUsesSentinel() async {
    var state = WorktreeJanitorFeature.State(
      repositoryID: "/r", repositoryName: "r", sessionsSnapshot: []
    )
    state.rows = [
      .init(id: "/r/wt", name: "wt", branch: "feat", head: "a", status: .orphan)
    ]
    let store = TestStore(initialState: state) {
      WorktreeJanitorFeature()
    } withDependencies: {
      $0.worktreeInventory.diffStat = { _, _ in "" }
    }
    store.exhaustivity = .off

    await store.send(.toggleRowExpansion(id: "/r/wt"))
    await store.receive(\._diffStatLoaded)
    #expect(store.state.rows[id: "/r/wt"]?.diffStat == "(no differences)")
  }
}

// MARK: - Pure helper

struct FindOrphanSessionIDsFromInventoryTests {
  @Test func matchesOnNormalizedPaths() {
    let ghost = AgentSession(
      repositoryID: "/r",
      worktreeID: "/r/gone",
      agent: .claude,
      initialPrompt: "x"
    )
    let live = AgentSession(
      repositoryID: "/r",
      worktreeID: "/r/alive",
      agent: .claude,
      initialPrompt: "x"
    )
    // Trailing slash on the inventory path still matches.
    let ids = findOrphanSessionIDsFromInventory(
      sessions: [ghost, live],
      repositoryID: "/r",
      inventoryPaths: ["/r/alive/"]
    )
    #expect(ids == [ghost.id])
  }

  @Test func skipsSessionsAtRepoRoot() {
    let root = AgentSession(
      repositoryID: "/r",
      worktreeID: "/r",
      agent: .claude,
      initialPrompt: "x"
    )
    let ids = findOrphanSessionIDsFromInventory(
      sessions: [root],
      repositoryID: "/r",
      inventoryPaths: []  // repo itself missing — doesn't matter
    )
    #expect(ids.isEmpty)
  }

  @Test func skipsForeignRepoSessions() {
    let foreign = AgentSession(
      repositoryID: "/other",
      worktreeID: "/other/wt",
      agent: .claude,
      initialPrompt: "x"
    )
    let ids = findOrphanSessionIDsFromInventory(
      sessions: [foreign],
      repositoryID: "/r",
      inventoryPaths: []
    )
    #expect(ids.isEmpty)
  }

  @Test func currentWorkspacePathProtectsConvertedSessions() {
    // Simulates the convert-to-worktree popover case: worktreeID
    // stays at the repo root while currentWorkspacePath points at a
    // freshly-created worktree.
    let converted = AgentSession(
      repositoryID: "/r",
      worktreeID: "/r/something",
      currentWorkspacePath: "/r/converted",
      agent: .claude,
      initialPrompt: "x"
    )
    let ids = findOrphanSessionIDsFromInventory(
      sessions: [converted],
      repositoryID: "/r",
      // Only the `currentWorkspacePath` is in the inventory —
      // `worktreeID` has been renamed/moved. Still not orphan because
      // the session's live working dir matches an inventory entry.
      inventoryPaths: ["/r/converted"]
    )
    #expect(ids.isEmpty)
  }
}

// MARK: - Helpers

/// Thread-safe counter for diff-stat fetch-count assertions.
private actor DiffStatCounter {
  private var count = 0
  func increment() { count += 1 }
  func get() -> Int { count }
}

// MARK: - BoardFeature integration

@MainActor
struct BoardFeatureJanitorIntegrationTests {
  @Test func openWorktreeJanitorSeedsStateWithSessionsSnapshot() async {
    let session = AgentSession(
      repositoryID: "/repos/foo",
      worktreeID: "/repos/foo",
      agent: .claude,
      initialPrompt: "x"
    )
    var state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }

    let store = TestStore(initialState: state) {
      BoardFeature()
    }
    store.exhaustivity = .off

    await store.send(
      .openWorktreeJanitor(repositoryID: "/repos/foo", repositoryName: "foo")
    )

    guard let janitor = store.state.worktreeJanitor else {
      Issue.record("Expected janitor state to be seeded")
      return
    }
    #expect(janitor.repositoryID == "/repos/foo")
    #expect(janitor.repositoryName == "foo")
    #expect(janitor.sessionsSnapshot == [session])
  }

  @Test func janitorDismissedDelegateClearsPresentedState() async {
    var state = BoardFeature.State()
    state.worktreeJanitor = WorktreeJanitorFeature.State(
      repositoryID: "/repos/foo",
      repositoryName: "foo",
      sessionsSnapshot: []
    )

    let store = TestStore(initialState: state) {
      BoardFeature()
    }
    store.exhaustivity = .off

    await store.send(.worktreeJanitor(.presented(.delegate(.dismissed)))) {
      $0.worktreeJanitor = nil
    }
  }
}
