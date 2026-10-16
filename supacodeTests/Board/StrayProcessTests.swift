import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import Supacool

/// Detached processes left running in a repo's worktrees: classification,
/// scan roots, and the Janitor's list-and-stop flow.
@MainActor
struct StrayProcessTests {
  nonisolated private static let started = Date(timeIntervalSince1970: 1_700_000_000)

  nonisolated private static func candidate(
    pid: pid_t,
    cwd: String,
    descendants: [pid_t] = []
  ) -> StrayProcessCandidate {
    StrayProcessCandidate(
      pid: pid,
      cwd: cwd,
      command: "node pnpm run dev",
      startedAt: started.addingTimeInterval(TimeInterval(pid)),
      descendantPIDs: descendants
    )
  }

  // MARK: - classifyStrayProcesses

  @Test func classifiesByTheInnermostWorktreeAndSkipsTheRepoRoot() {
    let rows = [
      WorktreeInventoryEntry(id: "/repos/foo", name: "foo", branch: "main", head: "r", status: .repoRoot),
      WorktreeInventoryEntry(
        id: "/base/foo/owned", name: "owned", branch: "a", head: "a",
        status: .owned(sessionID: UUID(), displayName: "Card")
      ),
      WorktreeInventoryEntry(id: "/base/foo/nest/wt", name: "wt", branch: "b", head: "b", status: .orphan),
    ]
    let strays = classifyStrayProcesses(
      candidates: [
        Self.candidate(pid: 1, cwd: "/base/foo/owned/webapp"),
        Self.candidate(pid: 2, cwd: "/base/foo/nest/wt/"),
        Self.candidate(pid: 3, cwd: "/base/foo/nest/deleted/webapp"),
        Self.candidate(pid: 4, cwd: "/repos/foo"),
      ],
      rows: rows
    )

    #expect(strays.map(\.pid) == [1, 2, 3])
    #expect(strays.map(\.status) == [.cardOnBoard, .noCard, .worktreeGone])
    #expect(strays.map(\.worktreePath) == ["/base/foo/owned", "/base/foo/nest/wt", nil])
    #expect(strays.map(\.isPreselected) == [false, true, true])
  }

  // MARK: - strayScanRoots

  @Test func scanRootsAreTheBaseDirectoryPlusWorktreesOutsideIt() {
    let rows = [
      WorktreeInventoryEntry(id: "/repos/foo", name: "foo", branch: "main", head: "r", status: .repoRoot),
      WorktreeInventoryEntry(id: "/base/foo/wt", name: "wt", branch: "a", head: "a", status: .orphan),
      WorktreeInventoryEntry(id: "/elsewhere/wt2", name: "wt2", branch: "b", head: "b", status: .orphan),
    ]
    #expect(
      strayScanRoots(rows: rows, worktreeBaseDirectoryPath: "/base/foo/", repositoryID: "/repos/foo")
        == ["/base/foo", "/elsewhere/wt2"]
    )
  }

  @Test func scanRootsLeaveOutTheRepoRootWhenWorktreesLiveInRepo() {
    let rows = [
      WorktreeInventoryEntry(id: "/repos/foo", name: "foo", branch: "main", head: "r", status: .repoRoot),
      WorktreeInventoryEntry(id: "/repos/foo/.wt/a", name: "a", branch: "a", head: "a", status: .orphan),
    ]
    #expect(
      strayScanRoots(rows: rows, worktreeBaseDirectoryPath: "/repos/foo", repositoryID: "/repos/foo")
        == ["/repos/foo/.wt/a"]
    )
  }

  // MARK: - descendants

  @Test func descendantsWalkTheWholeSubtreeOnce() {
    let tree: [pid_t: [pid_t]] = [10: [11, 12], 11: [13], 13: [10]]
    #expect(descendants(of: 10, in: tree) == [11, 12, 13])
  }

  // MARK: - Janitor flow

  @Test func scanListsStraysAndStopTerminatesTheSelectedTrees() async {
    let repoRoot = "/repos/foo"
    let base = normalizePath(
      SupacoolPaths.repositoryDirectory(for: URL(fileURLWithPath: repoRoot)).path(percentEncoded: false)
    )
    let gone = Self.candidate(pid: 41, cwd: "\(base)/deleted/webapp", descendants: [42])
    let idle = Self.candidate(pid: 51, cwd: "/repos/foo-wt/webapp")
    let scannedRoots = LockIsolated<[[String]]>([])
    let terminated = LockIsolated<[pid_t]>([])
    let clock = TestClock()
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
          GitWtWorktreeEntry(branch: "wt", path: "/repos/foo-wt", head: "w", isBare: false),
        ]
      }
      $0.worktreeInventory.listFolders = { _ in [] }
      $0.worktreeInventory.measure = { _ in 0 }
      $0.worktreeInventory.gitMetadata = { _, _ in WorktreeInventoryGitMetadata() }
      $0.strayProcesses.scan = { roots, _ in
        scannedRoots.withValue { $0.append(roots) }
        return terminated.value.isEmpty ? [gone, idle] : [idle]
      }
      $0.strayProcesses.terminate = { pids in
        terminated.withValue { $0.append(contentsOf: pids) }
        return []
      }
      $0.continuousClock = clock
    }
    store.exhaustivity = .off

    await store.send(.scanRequested)
    await store.receive(\._strayProcessesLoaded) {
      #expect($0.strayProcesses.map(\.status) == [.worktreeGone, .noCard])
      $0.selectedStrayPIDs = [41, 51]
    }
    #expect(scannedRoots.value == [[base, "/repos/foo-wt"]])
    await store.receive(\._scanCompleted)

    // Keep the idle one, stop the one whose worktree is gone.
    await store.send(.toggleStraySelection(pid: 51)) {
      $0.selectedStrayPIDs = [41]
    }
    await store.send(.stopSelectedStraysRequested) {
      $0.isStoppingStrays = true
    }
    await clock.advance(by: .seconds(1))
    await store.receive(\._straysStopped) {
      $0.isStoppingStrays = false
      $0.selectedStrayPIDs = []
      $0.strayStopErrors = []
    }
    #expect(terminated.value == [41, 42])
    #expect(store.state.strayProcesses.map(\.pid) == [51])
  }

  @Test func aProcessThatSurvivesSIGTERMIsReported() async {
    let survivor = StrayProcess(
      pid: 7, cwd: "/gone/wt", command: "vite", startedAt: Self.started,
      descendantPIDs: [], worktreePath: nil, status: .worktreeGone
    )
    let clock = TestClock()
    var state = WorktreeJanitorFeature.State(repositoryID: "/repos/foo", repositoryName: "foo", sessionsSnapshot: [])
    state.strayProcesses = [survivor]
    state.selectedStrayPIDs = [7]
    let store = TestStore(initialState: state) {
      WorktreeJanitorFeature()
    } withDependencies: {
      $0.strayProcesses.scan = { _, _ in
        [Self.candidate(pid: 7, cwd: "/gone/wt")]
      }
      $0.strayProcesses.terminate = { _ in [] }
      $0.continuousClock = clock
    }

    await store.send(.stopSelectedStraysRequested) {
      $0.isStoppingStrays = true
    }
    await clock.advance(by: .seconds(1))
    await store.receive(\._straysStopped) {
      $0.isStoppingStrays = false
      $0.strayProcesses = [
        StrayProcess(
          pid: 7, cwd: "/gone/wt", command: "node pnpm run dev",
          startedAt: Self.started.addingTimeInterval(7),
          descendantPIDs: [], worktreePath: nil, status: .worktreeGone
        ),
      ]
      $0.strayStopErrors = ["pid 7: still running after SIGTERM"]
    }
  }
}
