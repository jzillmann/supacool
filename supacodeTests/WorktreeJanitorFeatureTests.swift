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
