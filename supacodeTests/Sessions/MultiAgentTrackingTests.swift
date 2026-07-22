import ConcurrencyExtras
import Dependencies
import DependenciesTestSupport
import Foundation
import Sharing
import Testing

@testable import Supacool

/// Multi-agent-per-session tracking: surface-keyed session-id capture,
/// pane auto-adoption, shell promotion, surface-scoped busy clearing, and
/// the working-wins activity merge.
@MainActor
@Suite(.dependencies { $0.date.now = Date(timeIntervalSince1970: 1_234) })
struct MultiAgentTrackingTests {

  // MARK: - Capture resolution & adoption

  /// The historical bug: a hand-typed same-type agent in a ⌘E split shares
  /// the primary's SUPACOOL_TAB_ID, and its hook used to overwrite the
  /// primary's captured resume id. It must adopt a pane terminal instead.
  @Test func sameAgentPaneNotificationAdoptsInsteadOfOverwritingPrimary() {
    let fixture = makeSessionFixture(agent: .claude)
    let paneSurfaceID = UUID()
    fixture.state.registerTestSurface(paneSurfaceID, tabID: fixture.tabID)

    // Primary agent reports from the creation surface.
    fixture.server.onNotification?(
      fixture.worktree.id,
      fixture.tabID.rawValue,
      fixture.creationSurfaceID,
      notification(agent: "claude", sessionID: "claude-primary-1")
    )
    // A second claude, hand-typed into a split pane, reports from its own
    // surface.
    fixture.server.onNotification?(
      fixture.worktree.id,
      fixture.tabID.rawValue,
      paneSurfaceID,
      notification(agent: "claude", sessionID: "claude-pane-1")
    )

    @Shared(.agentSessions) var sessions: [AgentSession]
    let session = sessions[0]
    #expect(session.primaryTerminal.agentNativeSessionID == "claude-primary-1")
    #expect(session.terminals.count == 2)
    let pane = session.terminals.first { $0.hostTabID != nil }
    #expect(pane?.id == paneSurfaceID)
    #expect(pane?.role == .agent)
    #expect(pane?.agent == .claude)
    #expect(pane?.hostTabID == fixture.tabID.rawValue)
    #expect(pane?.agentNativeSessionID == "claude-pane-1")
    #expect(session.agentTerminals.count == 2)
  }

  /// A different agent typed into a split is adopted with its own type —
  /// previously its hook was silently dropped by the foreign-agent guard.
  @Test func foreignAgentInPaneIsAdoptedNotDropped() {
    let fixture = makeSessionFixture(agent: .claude)
    let paneSurfaceID = UUID()
    fixture.state.registerTestSurface(paneSurfaceID, tabID: fixture.tabID)

    fixture.server.onNotification?(
      fixture.worktree.id,
      fixture.tabID.rawValue,
      paneSurfaceID,
      notification(agent: "codex", sessionID: "codex-pane-1")
    )

    @Shared(.agentSessions) var sessions: [AgentSession]
    let pane = sessions[0].terminals.first { $0.hostTabID != nil }
    #expect(pane?.agent == .codex)
    #expect(pane?.agentNativeSessionID == "codex-pane-1")
    // Primary untouched.
    #expect(sessions[0].primaryTerminal.agent == .claude)
    #expect(sessions[0].primaryTerminal.agentNativeSessionID == nil)
  }

  /// On a TAB terminal the foreign-agent guard still drops mismatched
  /// hooks from the tab's own (creation) surface — the terminal "is" what
  /// it was launched as.
  @Test func foreignAgentOnTabTerminalCreationSurfaceStillDropped() {
    let fixture = makeSessionFixture(agent: .claude)

    fixture.server.onNotification?(
      fixture.worktree.id,
      fixture.tabID.rawValue,
      fixture.creationSurfaceID,
      notification(agent: "codex", sessionID: "codex-rogue-1")
    )

    @Shared(.agentSessions) var sessions: [AgentSession]
    #expect(sessions[0].primaryTerminal.agent == .claude)
    #expect(sessions[0].primaryTerminal.agentNativeSessionID == nil)
    #expect(sessions[0].terminals.count == 1)
  }

  /// A shell terminal (agent == nil) where the user hand-types an agent is
  /// promoted in place: role flips to .agent and the id is captured.
  @Test func shellTabTerminalPromotesToAgentOnHook() {
    let fixture = makeSessionFixture(agent: nil)

    fixture.server.onNotification?(
      fixture.worktree.id,
      fixture.tabID.rawValue,
      fixture.creationSurfaceID,
      notification(agent: "claude", sessionID: "claude-promoted-1")
    )

    @Shared(.agentSessions) var sessions: [AgentSession]
    let primary = sessions[0].primaryTerminal
    #expect(primary.role == .agent)
    #expect(primary.agent == .claude)
    #expect(primary.agentNativeSessionID == "claude-promoted-1")
  }

  /// Panes are user-driven: exiting claude and typing codex in the SAME
  /// pane re-adopts the pane record with the latest agent.
  @Test func paneReAdoptsLatestAgent() {
    let fixture = makeSessionFixture(agent: .claude)
    let paneSurfaceID = UUID()
    fixture.state.registerTestSurface(paneSurfaceID, tabID: fixture.tabID)

    fixture.server.onNotification?(
      fixture.worktree.id,
      fixture.tabID.rawValue,
      paneSurfaceID,
      notification(agent: "claude", sessionID: "claude-pane-1")
    )
    fixture.server.onNotification?(
      fixture.worktree.id,
      fixture.tabID.rawValue,
      paneSurfaceID,
      notification(agent: "codex", sessionID: "codex-pane-2")
    )

    @Shared(.agentSessions) var sessions: [AgentSession]
    let panes = sessions[0].terminals.filter { $0.hostTabID != nil }
    #expect(panes.count == 1)
    #expect(panes[0].agent == .codex)
    #expect(panes[0].agentNativeSessionID == "codex-pane-2")
    #expect(panes[0].hasCompletedAtLeastOnce == false)
  }

  /// Without a known creation surface (legacy tabs), hooks keep resolving
  /// to the tab terminal — no adoption, today's attribution.
  @Test func unknownCreationSurfaceFallsBackToTabTerminal() {
    let fixture = makeSessionFixture(agent: .claude, registerCreationSurface: false)
    let otherSurfaceID = UUID()
    fixture.state.registerTestSurface(otherSurfaceID, tabID: fixture.tabID)

    fixture.server.onNotification?(
      fixture.worktree.id,
      fixture.tabID.rawValue,
      otherSurfaceID,
      notification(agent: "claude", sessionID: "claude-legacy-1")
    )

    @Shared(.agentSessions) var sessions: [AgentSession]
    #expect(sessions[0].primaryTerminal.agentNativeSessionID == "claude-legacy-1")
    #expect(sessions[0].terminals.count == 1)
  }

  // MARK: - Surface-scoped busy + working wins

  /// An awaiting-input hook from one pane must not wipe a sibling agent's
  /// busy latch, and while the sibling still works the tab reads .working
  /// (working wins). Once the sibling finishes, the pending awaiting
  /// signal surfaces as .wantsInput.
  @Test func awaitingFromPaneKeepsSiblingWorking() async {
    await withMainSerialExecutor {
      let clock = TestClock()
      let server = AgentHookSocketServer(testingSocketPath: "/tmp/supacool-test-multiagent-busy")
      let manager = WorktreeTerminalManager(
        runtime: GhosttyRuntime(),
        socketServer: server,
        awaitingInputTransitionOnDebounce: .milliseconds(250),
        awaitingInputTransitionOffDebounce: .milliseconds(250),
        clock: clock
      )
      let worktree = makeWorktree()
      let sessionID = UUID()
      let state = manager.state(for: worktree)
      let tab = state.registerTestTab(tabID: sessionID)
      let tabID = tab.tabId
      state.registerTestCreationSurface(tab.surfaceID, tabID: tabID)
      let paneSurfaceID = UUID()
      state.registerTestSurface(paneSurfaceID, tabID: tabID)
      registerSession(id: sessionID, agent: .claude, worktree: worktree)

      // Sibling (primary surface) working, pane working.
      server.onBusy?(worktree.id, tabID.rawValue, tab.surfaceID, true, 101)
      server.onBusy?(worktree.id, tabID.rawValue, paneSurfaceID, true, 202)
      #expect(manager.agentActivity(worktreeID: worktree.id, tabID: tabID) == .working)

      // The pane's agent asks for permission — hook-sourced awaiting.
      server.onNotification?(
        worktree.id,
        tabID.rawValue,
        paneSurfaceID,
        notification(
          agent: "claude",
          event: "Notification",
          body: "Claude needs your permission to use Bash",
          sessionID: nil
        )
      )
      await Task.yield()
      await clock.advance(by: .milliseconds(250))

      // The pane's latch is cleared, the sibling's survives → working wins.
      #expect(state.hasAgentBusyLatch(tabID))
      #expect(manager.agentActivity(worktreeID: worktree.id, tabID: tabID) == .working)

      // Sibling finishes → the pending permission prompt surfaces.
      server.onBusy?(worktree.id, tabID.rawValue, tab.surfaceID, false, 101)
      #expect(!state.hasAgentBusyLatch(tabID))
      #expect(manager.agentActivity(worktreeID: worktree.id, tabID: tabID) == .wantsInput)
    }
  }

  /// Session-level activity merges across agent-hosting tabs: an agent
  /// busy in an auxiliary tab keeps the whole session .working.
  @Test func sessionActivityMergesAcrossTabs() {
    let fixture = makeSessionFixture(agent: .claude)
    // Register an aux agent tab on the session.
    let auxTabInfo = fixture.state.registerTestTab()
    @Shared(.agentSessions) var sessions: [AgentSession]
    $sessions.withLock {
      $0[0].terminals.append(
        SessionTerminal(id: auxTabInfo.tabId.rawValue, role: .agent, agent: .codex)
      )
    }

    // Only the aux tab's agent is busy.
    fixture.server.onBusy?(
      fixture.worktree.id, auxTabInfo.tabId.rawValue, auxTabInfo.surfaceID, true, 303
    )

    #expect(
      fixture.manager.agentActivity(worktreeID: fixture.worktree.id, tabID: fixture.tabID) == .idle
    )
    #expect(fixture.manager.sessionActivity(for: sessions[0]) == .working)
    #expect(fixture.manager.isSessionBusy(for: sessions[0]))
  }

  // MARK: - Activity merge (pure)

  @Test func mergedWorkingWinsMatrix() {
    #expect(AgentActivity.mergedWorkingWins([.working, .idle]) == .working)
    #expect(AgentActivity.mergedWorkingWins([.wantsInput, .working]) == .working)
    #expect(AgentActivity.mergedWorkingWins([.wantsInput, .deferredWork]) == .deferredWork)
    #expect(AgentActivity.mergedWorkingWins([.wantsInput, .idle]) == .wantsInput)
    #expect(AgentActivity.mergedWorkingWins([.idle, .idle]) == .idle)
    #expect(AgentActivity.mergedWorkingWins([]) == .idle)
    // Identity for single elements — single-agent sessions unchanged.
    for activity in [AgentActivity.working, .wantsInput, .deferredWork, .idle] {
      #expect(AgentActivity.mergedWorkingWins([activity]) == activity)
    }
  }

  // MARK: - Classifier

  /// A relaunch with only a SECONDARY agent mid-turn must classify
  /// .interrupted — a working secondary is as visible as a working primary.
  @Test func interruptedWhenOnlySecondaryTerminalWasBusy() {
    var session = AgentSession(
      repositoryID: "/tmp/repo",
      worktreeID: "/tmp/repo",
      agent: .claude,
      initialPrompt: "p"
    )
    session.terminals.append(
      SessionTerminal(
        id: UUID(),
        role: .agent,
        hostTabID: session.id,
        agent: .codex,
        lastKnownBusy: true
      )
    )

    let status = BoardSessionStatus.classify(
      session: session,
      tabExists: false,
      activity: .idle
    )
    #expect(status == .interrupted)
  }

  /// A busy SHELL auxiliary must not fake an interruption.
  @Test func detachedWhenOnlyShellAuxiliaryWasBusy() {
    var session = AgentSession(
      repositoryID: "/tmp/repo",
      worktreeID: "/tmp/repo",
      agent: .claude,
      initialPrompt: "p"
    )
    session.terminals.append(
      SessionTerminal(id: UUID(), role: .shell, lastKnownBusy: true)
    )

    let status = BoardSessionStatus.classify(
      session: session,
      tabExists: false,
      activity: .idle
    )
    #expect(status == .detached)
  }

  // MARK: - Helpers

  private struct SessionFixture {
    let manager: WorktreeTerminalManager
    let server: AgentHookSocketServer
    let state: WorktreeTerminalState
    let worktree: Worktree
    let sessionID: UUID
    let tabID: TerminalTabID
    let creationSurfaceID: UUID
  }

  /// One session with one registered test tab whose creation surface is
  /// known (unless `registerCreationSurface: false` emulates legacy tabs).
  private func makeSessionFixture(
    agent: AgentType?,
    registerCreationSurface: Bool = true
  ) -> SessionFixture {
    let server = AgentHookSocketServer(
      testingSocketPath: "/tmp/supacool-test-multiagent-\(UUID().uuidString.prefix(8))"
    )
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime(), socketServer: server)
    let worktree = makeWorktree()
    let sessionID = UUID()
    let state = manager.state(for: worktree)
    let tab = state.registerTestTab(tabID: sessionID)
    if registerCreationSurface {
      state.registerTestCreationSurface(tab.surfaceID, tabID: tab.tabId)
    }
    registerSession(id: sessionID, agent: agent, worktree: worktree)
    return SessionFixture(
      manager: manager,
      server: server,
      state: state,
      worktree: worktree,
      sessionID: sessionID,
      tabID: tab.tabId,
      creationSurfaceID: tab.surfaceID
    )
  }

  private func registerSession(id: UUID, agent: AgentType?, worktree: Worktree) {
    @Shared(.agentSessions) var sessions: [AgentSession]
    $sessions.withLock {
      $0 = [
        AgentSession(
          id: id,
          repositoryID: worktree.id,
          worktreeID: worktree.id,
          agent: agent,
          initialPrompt: agent == nil ? "" : "work on it"
        ),
      ]
    }
  }

  private func notification(
    agent: String,
    event: String = "Stop",
    body: String? = nil,
    sessionID: String?
  ) -> AgentHookNotification {
    AgentHookNotification(
      agent: agent,
      event: event,
      title: nil,
      body: body,
      sessionID: sessionID
    )
  }

  private func makeWorktree() -> Worktree {
    let id = "/tmp/repo/wt-multiagent"
    return Worktree(
      id: id,
      name: "wt-multiagent",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: id),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
  }
}
