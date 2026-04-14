import Dependencies
import DependenciesTestSupport
import Foundation
import Testing

@testable import supacode

/// Exercises `WorktreeTerminalState.splitFocusedSurface`, the helper Supacool's
/// `FullScreenTerminalView` uses to open a bare-shell split alongside an
/// agent session without resurrecting the whole worktree tab bar.
@MainActor
struct WorktreeTerminalStateSplitTests {
  @Test(.dependencies) func splitWithoutFocusedSurfaceFails() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree) { false }

    // No tab has been created, so there's no focused surface. The helper
    // must refuse rather than crash.
    let result = state.splitFocusedSurface(
      in: TerminalTabID(rawValue: UUID()),
      direction: .right,
    )
    #expect(result == nil)
  }

  @Test(.dependencies) func splitAddsSecondLeafToTab() {
    let fixture = makeStateWithSurface()

    let before = fixture.state.splitTree(for: fixture.tabId).leaves()
    #expect(before.count == 1)

    let newID = fixture.state.splitFocusedSurface(in: fixture.tabId, direction: .right)
    #expect(newID != nil)

    let after = fixture.state.splitTree(for: fixture.tabId).leaves()
    #expect(after.count == 2)
    // The returned id must match the newly-created leaf (not the source).
    #expect(after.contains(where: { $0.id == newID }))
    #expect(newID != fixture.surface.id)
  }

  // MARK: - Helpers

  private func makeWorktree() -> Worktree {
    Worktree(
      id: "/tmp/repo/wt-1",
      name: "wt-1",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-1"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo"),
    )
  }

  private struct SurfaceFixture {
    let manager: WorktreeTerminalManager
    let state: WorktreeTerminalState
    let tabId: TerminalTabID
    let surface: GhosttySurfaceView
  }

  /// Mirrors the fixture in `AgentBusyStateTests` — primes the state with
  /// one tab/surface via a blocking-script command (the shortest path to
  /// an initialized split tree without booting a full ghostty app).
  private func makeStateWithSurface() -> SurfaceFixture {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    manager.handleCommand(.runBlockingScript(worktree, kind: .archive, script: "echo ok"))
    let state = manager.stateIfExists(for: worktree.id)!
    let tabId = state.tabManager.selectedTabId!
    let surface = state.splitTree(for: tabId).root!.leftmostLeaf()
    return SurfaceFixture(manager: manager, state: state, tabId: tabId, surface: surface)
  }
}
