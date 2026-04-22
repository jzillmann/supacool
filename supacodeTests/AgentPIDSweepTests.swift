import ConcurrencyExtras
import Dependencies
import DependenciesTestSupport
import Foundation
import Testing

@testable import Supacool

/// Verifies the 30s sweep that clears stale busy / awaiting-input state
/// if the agent process crashes before a clean hook fires. Without this
/// safety net a SIGKILL or OOM-killed Claude would leave the card stuck
/// in "Running" until the user manually closed the tab.
@MainActor
struct AgentPIDSweepTests {
  @Test(.dependencies) func busyPIDIsRegisteredOnActiveHook() {
    let fixture = makeFixture()
    let pid: Int32 = 12345

    fixture.fireBusy(active: true, pid: pid)

    #expect(fixture.manager.registeredAgentPID(tabID: fixture.tabID.rawValue) == pid)
    #expect(fixture.manager.taskStatus(for: fixture.worktree.id) == .running)
  }

  @Test(.dependencies) func busyPIDIsClearedOnInactiveHook() {
    let fixture = makeFixture()

    fixture.fireBusy(active: true, pid: 4242)
    fixture.fireBusy(active: false, pid: 4242)

    #expect(fixture.manager.registeredAgentPID(tabID: fixture.tabID.rawValue) == nil)
  }

  @Test(.dependencies) func sweepClearsBusyWhenRegisteredPIDIsDead() {
    let deadPID: Int32 = 77777
    let fixture = makeFixture(deadPIDs: [deadPID])

    fixture.fireBusy(active: true, pid: deadPID)
    #expect(fixture.manager.taskStatus(for: fixture.worktree.id) == .running)

    fixture.manager.sweepAgentPIDs()

    #expect(fixture.manager.taskStatus(for: fixture.worktree.id) == .idle)
    #expect(fixture.manager.registeredAgentPID(tabID: fixture.tabID.rawValue) == nil)
  }

  @Test(.dependencies) func sweepLeavesLiveAgentsAlone() {
    let fixture = makeFixture(deadPIDs: [])

    fixture.fireBusy(active: true, pid: 10001)
    fixture.manager.sweepAgentPIDs()

    #expect(fixture.manager.taskStatus(for: fixture.worktree.id) == .running)
    #expect(fixture.manager.registeredAgentPID(tabID: fixture.tabID.rawValue) == 10001)
  }

  @Test(.dependencies) func legacyHookWithoutPIDDoesNotRegister() {
    let fixture = makeFixture()

    // Pre-upgrade client: pid=nil. Busy state still toggles, but the
    // sweep has nothing to watch (legacy clients rely on the existing
    // Stop/SessionEnd path instead).
    fixture.fireBusy(active: true, pid: nil)

    #expect(fixture.manager.taskStatus(for: fixture.worktree.id) == .running)
    #expect(fixture.manager.registeredAgentPID(tabID: fixture.tabID.rawValue) == nil)
  }

  // MARK: - Helpers.

  private struct Fixture {
    let manager: WorktreeTerminalManager
    let worktree: Worktree
    let tabID: TerminalTabID
    let surfaceID: UUID

    func fireBusy(active: Bool, pid: Int32?) {
      manager.socketServer?.onBusy?(worktree.id, tabID.rawValue, surfaceID, active, pid)
    }
  }

  private func makeFixture(deadPIDs: Set<Int32> = []) -> Fixture {
    let deadSnapshot = deadPIDs
    let manager = WorktreeTerminalManager(
      runtime: GhosttyRuntime(),
      agentPIDSweepInterval: .seconds(3600),
      isProcessAlive: { pid in !deadSnapshot.contains(pid) }
    )
    let worktree = Worktree(
      id: "/tmp/pidsweep/wt-1",
      name: "wt-1",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: "/tmp/pidsweep/wt-1"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/pidsweep")
    )
    manager.handleCommand(.runBlockingScript(worktree, kind: .archive, script: "echo ok"))
    let state = manager.stateIfExists(for: worktree.id)!
    let tabID = state.tabManager.selectedTabId!
    let surface = state.splitTree(for: tabID).root!.leftmostLeaf()
    return Fixture(manager: manager, worktree: worktree, tabID: tabID, surfaceID: surface.id)
  }
}
