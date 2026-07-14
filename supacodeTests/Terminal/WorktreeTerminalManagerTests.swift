import Clocks
import ComposableArchitecture
import ConcurrencyExtras
import Dependencies
import Foundation
import Testing

@testable import Supacool

@MainActor
struct WorktreeTerminalManagerTests {
  @Test func reusesExistingStateAndReloadsSnapshotAfterRestoreIsEnabled() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let snapshot = makeLayoutSnapshot()
    var restoreEnabled = false

    manager.loadLayoutSnapshot = { _ in
      guard restoreEnabled else { return nil }
      return snapshot
    }

    let initialState = manager.state(for: worktree)
    #expect(initialState.pendingLayoutSnapshot == nil)

    restoreEnabled = true

    let reusedState = manager.state(for: worktree)
    #expect(reusedState === initialState)
    #expect(reusedState.pendingLayoutSnapshot == snapshot)
  }

  @Test func reusingExistingStateDoesNotReloadSnapshotWhenSetupScriptBecomesPending() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let snapshot = makeLayoutSnapshot()
    var restoreEnabled = false

    manager.loadLayoutSnapshot = { _ in
      guard restoreEnabled else { return nil }
      return snapshot
    }

    let initialState = manager.state(for: worktree)
    #expect(initialState.pendingLayoutSnapshot == nil)

    restoreEnabled = true

    let reusedState = manager.state(for: worktree) { true }
    #expect(reusedState === initialState)
    #expect(reusedState.needsSetupScript())
    #expect(reusedState.pendingLayoutSnapshot == nil)
  }

  @Test func pruneLayoutsForRemovedSessionDropsOnlyMatchingTabs() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let sessionAID = UUID()
    let sessionBID = UUID()
    let aPrimaryTab = UUID()
    let aShellTab = UUID()
    let bTab = UUID()
    let snapshot = TerminalLayoutSnapshot(
      tabs: [
        Self.simpleTabSnapshot(id: aPrimaryTab, sessionID: sessionAID),
        Self.simpleTabSnapshot(id: aShellTab, sessionID: sessionAID),
        Self.simpleTabSnapshot(id: bTab, sessionID: sessionBID),
      ],
      selectedTabIndex: 2
    )
    let loaded = LockIsolated(snapshot)
    let saved = LockIsolated<(Worktree.ID, TerminalLayoutSnapshot?)?>(nil)
    manager.loadSavedLayoutSnapshot = { _ in loaded.value }
    manager.saveLayoutSnapshot = { id, snap in saved.setValue((id, snap)) }

    manager.pruneLayoutsForRemovedSession(sessionID: sessionAID, worktreeID: worktree.id)

    let writeTuple = try? #require(saved.value)
    #expect(writeTuple?.0 == worktree.id)
    let writtenSnapshot = try? #require(writeTuple?.1)
    #expect(writtenSnapshot?.tabs.count == 1)
    #expect(writtenSnapshot?.tabs.first?.sessionID == sessionBID)
    #expect(writtenSnapshot?.tabs.first?.id == bTab)
    // selectedTabIndex was 2 but only 1 tab remains — should clamp.
    #expect(writtenSnapshot?.selectedTabIndex == 0)
  }

  @Test func pruneLayoutsForLastSessionInWorktreeDropsTheEntireSnapshot() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let sessionID = UUID()
    let snapshot = TerminalLayoutSnapshot(
      tabs: [
        Self.simpleTabSnapshot(id: UUID(), sessionID: sessionID),
        Self.simpleTabSnapshot(id: UUID(), sessionID: sessionID),
      ],
      selectedTabIndex: 0
    )
    let saved = LockIsolated<(Worktree.ID, TerminalLayoutSnapshot?)?>(nil)
    manager.loadSavedLayoutSnapshot = { _ in snapshot }
    manager.saveLayoutSnapshot = { id, snap in saved.setValue((id, snap)) }

    manager.pruneLayoutsForRemovedSession(sessionID: sessionID, worktreeID: worktree.id)

    let writeTuple = try? #require(saved.value)
    #expect(writeTuple?.0 == worktree.id)
    // All tabs belonged to the deleted session — entry is wiped.
    #expect(writeTuple?.1 == nil)
  }

  @Test func pruneLayoutsForUnknownWorktreeIsNoOp() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let saved = LockIsolated<(Worktree.ID, TerminalLayoutSnapshot?)?>(nil)
    manager.loadSavedLayoutSnapshot = { _ in nil }
    manager.saveLayoutSnapshot = { id, snap in saved.setValue((id, snap)) }

    manager.pruneLayoutsForRemovedSession(sessionID: UUID(), worktreeID: worktree.id)

    #expect(saved.value == nil)
  }

  /// Minimal `TabSnapshot` fixture for prune tests — the layout shape
  /// doesn't matter, only the id + sessionID.
  private static func simpleTabSnapshot(
    id: UUID,
    sessionID: UUID
  ) -> TerminalLayoutSnapshot.TabSnapshot {
    TerminalLayoutSnapshot.TabSnapshot(
      id: id,
      title: "",
      icon: nil,
      tintColor: nil,
      layout: .leaf(TerminalLayoutSnapshot.SurfaceSnapshot(id: UUID(), workingDirectory: nil)),
      focusedLeafIndex: 0,
      sessionID: sessionID
    )
  }

  @Test func restoreShellLayoutCommandRestoresSavedTabWithoutAutoRestoreSetting() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let tabID = TerminalTabID(rawValue: UUID())
    let snapshot = TerminalLayoutSnapshot(
      tabs: [
        TerminalLayoutSnapshot.TabSnapshot(
          id: tabID.rawValue,
          title: "shell",
          icon: "terminal",
          tintColor: nil,
          layout: .split(
            TerminalLayoutSnapshot.SplitSnapshot(
              direction: .horizontal,
              ratio: 0.4,
              left: .leaf(
                TerminalLayoutSnapshot.SurfaceSnapshot(id: UUID(), workingDirectory: "/tmp/repo/wt-1")
              ),
              right: .leaf(
                TerminalLayoutSnapshot.SurfaceSnapshot(id: UUID(), workingDirectory: "/tmp")
              )
            )
          ),
          focusedLeafIndex: 1
        ),
      ],
      selectedTabIndex: 0
    )
    manager.loadSavedLayoutSnapshot = { _ in snapshot }

    manager.handleCommand(.restoreShellLayout(worktree, tabID: tabID))

    guard let state = manager.stateIfExists(for: worktree.id) else {
      Issue.record("Expected restored terminal state")
      return
    }
    #expect(state.containsTabTree(tabID))
    #expect(state.tabManager.selectedTabId == tabID)
    #expect(state.splitTree(for: tabID).leaves().count == 2)
    #expect(state.pendingLayoutSnapshot == nil)
  }

  @Test func buffersEventsUntilStreamCreated() async {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    state.onSetupScriptConsumed?()

    let stream = manager.eventStream()
    let event = await nextEvent(stream) { event in
      if case .setupScriptConsumed = event {
        return true
      }
      return false
    }

    #expect(event == .setupScriptConsumed(worktreeID: worktree.id))
  }

  @Test func emitsEventsAfterStreamCreated() async {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    let stream = manager.eventStream()
    let eventTask = Task {
      await nextEvent(stream) { event in
        if case .setupScriptConsumed = event {
          return true
        }
        return false
      }
    }

    state.onSetupScriptConsumed?()

    let event = await eventTask.value
    #expect(event == .setupScriptConsumed(worktreeID: worktree.id))
  }

  @Test func unavailableSocketServerIsDiscarded() {
    let server = AgentHookSocketServer()
    server.shutdown()

    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime(), socketServer: server)
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    #expect(manager.socketServer == nil)
    #expect(state.socketPath == nil)
  }

  @Test func socketBusyRoutesToDecodedWorktreeState() {
    let server = AgentHookSocketServer(testingSocketPath: "/tmp/supacool-test-socket-busy")
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime(), socketServer: server)
    let worktree = makeWorktree(id: "/tmp/repo/wt with spaces")

    guard let tab = makeTab(in: manager, for: worktree),
      let encodedID = worktree.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
    else {
      Issue.record("Expected tab and socket server")
      return
    }

    server.onBusy?(encodedID, tab.tabId.rawValue, tab.surfaceID, true, nil)

    #expect(manager.taskStatus(for: worktree.id) == .running)
  }

  @Test func socketNotificationRoutesToDecodedWorktreeState() {
    withDependencies {
      $0.date.now = Date(timeIntervalSince1970: 1_234)
    } operation: {
      let server = AgentHookSocketServer(testingSocketPath: "/tmp/supacool-test-socket-notification")
      let manager = WorktreeTerminalManager(runtime: GhosttyRuntime(), socketServer: server)
      let worktree = makeWorktree(id: "/tmp/repo/wt with spaces")

      guard let tab = makeTab(in: manager, for: worktree),
        let encodedID = worktree.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
        let state = manager.stateIfExists(for: worktree.id)
      else {
        Issue.record("Expected tab and socket server")
        return
      }

      server.onNotification?(
        encodedID,
        tab.tabId.rawValue,
        tab.surfaceID,
        AgentHookNotification(agent: "codex", event: "Stop", title: "Done", body: "All complete", sessionID: nil)
      )

      #expect(
        state.notifications.contains {
          $0.title == "Done" && $0.body == "All complete"
        }
      )
    }
  }

  @Test func notificationIndicatorUsesCurrentCountOnStreamStart() async {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    state.notifications = [
      WorktreeTerminalNotification(
        surfaceId: UUID(),
        title: "Unread",
        body: "body",
        isRead: false
      ),
    ]
    state.onNotificationIndicatorChanged?()
    state.notifications = [
      WorktreeTerminalNotification(
        surfaceId: UUID(),
        title: "Read",
        body: "body",
        isRead: true
      ),
    ]

    let stream = manager.eventStream()
    var iterator = stream.makeAsyncIterator()

    let first = await iterator.next()
    state.onSetupScriptConsumed?()
    let second = await iterator.next()

    #expect(first == .notificationIndicatorChanged(count: 0))
    #expect(second == .setupScriptConsumed(worktreeID: worktree.id))
  }

  @Test func taskStatusReflectsAnyRunningTab() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    #expect(manager.taskStatus(for: worktree.id) == .idle)

    guard
      let tab1 = state.createTab(),
      let tab2 = state.createTab(focusing: false),
      let surface1 = state.splitTree(for: tab1).root?.leftmostLeaf(),
      let surface2 = state.splitTree(for: tab2).root?.leftmostLeaf()
    else {
      Issue.record("Expected tabs and surfaces")
      return
    }

    #expect(manager.taskStatus(for: worktree.id) == .idle)

    surface2.bridge.state.agentBusy = true
    #expect(manager.taskStatus(for: worktree.id) == .running)

    surface1.bridge.state.agentBusy = true
    #expect(manager.taskStatus(for: worktree.id) == .running)

    surface2.bridge.state.agentBusy = false
    #expect(manager.taskStatus(for: worktree.id) == .running)

    surface1.bridge.state.agentBusy = false
    #expect(manager.taskStatus(for: worktree.id) == .idle)
  }

  @Test func hasUnseenNotificationsReflectsUnreadEntries() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    state.notifications = [
      makeNotification(isRead: true),
      makeNotification(isRead: true),
    ]

    #expect(manager.hasUnseenNotifications(for: worktree.id) == false)

    state.notifications.append(makeNotification(isRead: false))

    #expect(manager.hasUnseenNotifications(for: worktree.id) == true)
  }

  @Test func awaitingInputRequiresStabilizationAndExpires() async {
    await withMainSerialExecutor {
      await withDependencies {
        $0.date.now = Date(timeIntervalSince1970: 1234)
      } operation: {
        let clock = TestClock()
        let server = AgentHookSocketServer(testingSocketPath: "/tmp/supacool-test-awaiting-input")
        let manager = WorktreeTerminalManager(
          runtime: GhosttyRuntime(),
          socketServer: server,
          awaitingInputTTL: .seconds(8),
          awaitingInputTransitionOnDebounce: .milliseconds(250),
          awaitingInputTransitionOffDebounce: .milliseconds(250),
          awaitingInputActivityPollInterval: .seconds(1),
          clock: clock
        )
        let worktree = makeWorktree()

        guard let tab = makeTab(in: manager, for: worktree) else {
          Issue.record("Expected tab and surface")
          return
        }
        let tabId = tab.tabId

        server.onNotification?(
          worktree.id,
          tabId.rawValue,
          tab.surfaceID,
          AgentHookNotification(
            agent: "claude",
            event: "Notification",
            title: nil,
            body: "Claude needs your permission to use Bash",
            sessionID: nil
          )
        )
        await Task.yield()

        #expect(!manager.isAwaitingInput(worktreeID: worktree.id, tabID: tabId))

        await clock.advance(by: .milliseconds(250))
        #expect(manager.isAwaitingInput(worktreeID: worktree.id, tabID: tabId))

        await clock.advance(by: .seconds(7) + .milliseconds(750))
        #expect(manager.isAwaitingInput(worktreeID: worktree.id, tabID: tabId))

        await clock.advance(by: .milliseconds(250))
        #expect(!manager.isAwaitingInput(worktreeID: worktree.id, tabID: tabId))
      }
    }
  }

  /// Regression (trace D5AF6FE4). A Claude turn spent *thinking* emits no busy
  /// hook at all: `UserPromptSubmit` and `PreToolUse` are the only busy-on
  /// edges, so a stretch of pure reasoning with no tool call is hook-silent for
  /// minutes. Replays the trace exactly — a blocking-tool Notification clears
  /// the busy latch and raises the awaiting lease, the lease expires 8s later,
  /// and the agent then thinks for 2.5 minutes with the interrupt hint on
  /// screen. The card used to sit in "Waiting" for that entire stretch while
  /// the terminal plainly read "thinking more".
  ///
  /// It must read Working the whole time, and fall to idle only once the hint
  /// actually leaves the screen.
  @Test func thinkingAfterAwaitingLeaseExpiresKeepsCardWorking() async {
    await withMainSerialExecutor {
      await withDependencies {
        $0.date.now = Date(timeIntervalSince1970: 1234)
      } operation: {
        let clock = TestClock()
        let server = AgentHookSocketServer(testingSocketPath: "/tmp/supacool-test-thinking-gap")
        // Step 1: the blocking tool (AskUserQuestion) has painted its prompt.
        let screenContents = LockIsolated(
          """
          Do you want to proceed?
          1. Yes
          2. No

          Esc to cancel
          """
        )
        let worktree = makeWorktree()
        let manager = WorktreeTerminalManager(
          runtime: GhosttyRuntime(),
          socketServer: server,
          awaitingInputTTL: .seconds(8),
          awaitingInputTransitionOnDebounce: .milliseconds(250),
          awaitingInputTransitionOffDebounce: .milliseconds(250),
          awaitingInputActivityPollInterval: .seconds(1),
          screenWorkingMissGrace: 3,
          startPromptScreenScanning: false,
          clock: clock,
          readScreenContents: { _, _ in screenContents.value }
        )

        let sessionID = UUID()
        let state = manager.state(for: worktree)
        let tab = state.registerTestTab(tabID: sessionID)
        let tabID = tab.tabId

        @Shared(.agentSessions) var sessions: [AgentSession]
        $sessions.withLock {
          $0 = [
            AgentSession(
              id: sessionID,
              repositoryID: worktree.id,
              worktreeID: worktree.id,
              agent: .claude,
              initialPrompt: "Plan CEN-7715",
            ),
          ]
        }

        // The synthetic "waiting for your input" Notification a blocking tool
        // fires *instead of* busy-on. It clears the busy latch by design.
        server.onNotification?(
          worktree.id,
          tabID.rawValue,
          tab.surfaceID,
          AgentHookNotification(
            agent: "claude",
            event: "Notification",
            title: nil,
            body: "Claude is waiting for your input",
            sessionID: nil
          )
        )
        await Task.yield()
        await clock.advance(by: .milliseconds(250))
        #expect(manager.agentActivity(worktreeID: worktree.id, tabID: tabID) == .wantsInput)

        // Step 2: the user answers. Claude drops the prompt and starts thinking
        // — no tool call yet, so not a single hook fires from here on.
        screenContents.setValue(
          """
          ⏺ Confirmed the two key facts. Rewriting the plan now.

          ✻ Growing… (3× 47s · ↑ 4.3k tokens · esc to interrupt)
          """
        )

        // Step 3: the awaiting lease expires (the old bug's trigger).
        await clock.advance(by: .seconds(8))
        await manager.sampleAwaitingInputPromptScreensForTesting()
        #expect(!manager.isAwaitingInput(worktreeID: worktree.id, tabID: tabID))

        // ...and the card is Working, on the strength of the footer alone.
        #expect(manager.isAgentBusy(worktreeID: worktree.id, tabID: tabID))
        #expect(manager.agentActivity(worktreeID: worktree.id, tabID: tabID) == .working)

        // Step 4: 2.5 minutes of hook-silent thinking. Card must not budge.
        for _ in 0..<150 {
          await clock.advance(by: .seconds(1))
          await manager.sampleAwaitingInputPromptScreensForTesting()
        }
        #expect(manager.agentActivity(worktreeID: worktree.id, tabID: tabID) == .working)

        // Step 5: the turn really ends — the hint leaves the screen. The lease
        // drops after `screenWorkingMissGrace` consecutive misses, not instantly.
        screenContents.setValue(
          """
          ⏺ Posted the plan to Linear.

          >
          """
        )
        await manager.sampleAwaitingInputPromptScreensForTesting()
        #expect(manager.agentActivity(worktreeID: worktree.id, tabID: tabID) == .working)

        for _ in 0..<3 {
          await clock.advance(by: .seconds(1))
          await manager.sampleAwaitingInputPromptScreensForTesting()
        }
        #expect(!manager.isAgentBusy(worktreeID: worktree.id, tabID: tabID))
        #expect(manager.agentActivity(worktreeID: worktree.id, tabID: tabID) == .idle)
      }
    }
  }

  /// A permission prompt is the *opposite* of working, and its footer reads
  /// "Esc to cancel" — one word away from the interrupt hint. The working-screen
  /// scan must not promote it, or a card silently blocked on the user would sit
  /// in "Working" forever.
  @Test func approvalPromptScreenDoesNotPromoteWorking() async {
    await withMainSerialExecutor {
      await withDependencies {
        $0.date.now = Date(timeIntervalSince1970: 1234)
      } operation: {
        let clock = TestClock()
        let screenContents = LockIsolated(
          """
          Do you want to make this edit to widget.cue?
          1. Yes
          2. No

          Esc to cancel  Tab to amend
          """
        )
        let worktree = makeWorktree()
        let manager = WorktreeTerminalManager(
          runtime: GhosttyRuntime(),
          awaitingInputActivityPollInterval: .seconds(1),
          startPromptScreenScanning: false,
          clock: clock,
          readScreenContents: { _, _ in screenContents.value }
        )

        let sessionID = UUID()
        let state = manager.state(for: worktree)
        let tab = state.registerTestTab(tabID: sessionID)
        let tabID = tab.tabId

        @Shared(.agentSessions) var sessions: [AgentSession]
        $sessions.withLock {
          $0 = [
            AgentSession(
              id: sessionID,
              repositoryID: worktree.id,
              worktreeID: worktree.id,
              agent: .claude,
              initialPrompt: "Edit the widget",
            ),
          ]
        }

        await manager.sampleAwaitingInputPromptScreensForTesting()
        #expect(!manager.isAgentBusy(worktreeID: worktree.id, tabID: tabID))
      }
    }
  }

  /// Regression: a hooked agent (Claude/Codex) that fires a single
  /// "waiting for input" hook and then goes genuinely quiet — blocked on
  /// the user or a background process — must stay in the waiting bucket.
  /// Previously the 8s `awaitingInputTTL` was an absolute deadline that
  /// killed the latch even while the prompt was still on screen, silently
  /// dropping the card to idle (observed in trace BDDDC59F…, where three
  /// genuine "waiting for input" hooks each died `ttl-expired` +8s later).
  /// The per-tab activity poll now re-arms the TTL on every screen-confirmed
  /// poll, so the latch only expires once the surface stops confirming it.
  @Test func awaitingInputSurvivesPastTTLWhileScreenStaysQuiet() async {
    await withMainSerialExecutor {
      await withDependencies {
        $0.date.now = Date(timeIntervalSince1970: 1234)
      } operation: {
        let clock = TestClock()
        // A genuinely-idle prompt the agent yielded at — NOT a structured
        // approval prompt, so `isAwaitingInputPromptScreen` is false and the
        // keep-alive comes purely from the unchanged-fingerprint path.
        let screenContents = LockIsolated("❯\n  (waiting on background watch)")
        let server = AgentHookSocketServer(testingSocketPath: "/tmp/supacool-test-awaiting-input-quiet")
        let manager = WorktreeTerminalManager(
          runtime: GhosttyRuntime(),
          socketServer: server,
          awaitingInputTTL: .seconds(8),
          awaitingInputTransitionOnDebounce: .milliseconds(250),
          awaitingInputTransitionOffDebounce: .milliseconds(250),
          awaitingInputActivityPollInterval: .seconds(1),
          clock: clock,
          readScreenContents: { _, _ in screenContents.value }
        )
        let worktree = makeWorktree()

        guard let tab = makeTab(in: manager, for: worktree) else {
          Issue.record("Expected tab and surface")
          return
        }
        let tabId = tab.tabId

        server.onNotification?(
          worktree.id,
          tabId.rawValue,
          tab.surfaceID,
          AgentHookNotification(
            agent: "claude",
            event: "Notification",
            title: nil,
            body: "Claude is waiting for your input",
            sessionID: nil
          )
        )
        await Task.yield()

        await clock.advance(by: .milliseconds(250))
        #expect(manager.isAwaitingInput(worktreeID: worktree.id, tabID: tabId))

        // Hold the quiet prompt for well past the 8s TTL. Each 1s poll sees
        // an unchanged screen and re-arms the expiry, so the latch survives.
        for _ in 0..<12 {
          await clock.advance(by: .seconds(1))
          #expect(manager.isAwaitingInput(worktreeID: worktree.id, tabID: tabId))
        }

        // Once the surface visibly moves past the prompt, the activity poll
        // clears it via `activity-resumed` (not the TTL).
        screenContents.setValue("Resumed: building images\nStep 3/12")
        await clock.advance(by: .seconds(1))
        await clock.advance(by: .milliseconds(250))
        #expect(!manager.isAwaitingInput(worktreeID: worktree.id, tabID: tabId))
      }
    }
  }

  @Test func awaitingInputPromptScreenRecognizesCodexPermissionPrompt() {
    // Codex's PermissionRequest UI — the `activity-resumed` heuristic
    // uses `isAwaitingInputPromptScreen` to tell "prompt just finished
    // rendering after the hook fired" from "user moved on", so the
    // matcher must recognize the codex prompt shape, not just
    // claude's.
    let codexScreen = """
      Would you like to run the following command?

      Reason: build the app outside the sandbox

      |> make build-app

      1. Yes, proceed (y)
      2. Yes, and don't ask again for commands that start with `make build-app` (a)
      3. No, and tell Codex what to do differently (esc)

      Press enter to confirm or esc to cancel
      """
    #expect(WorktreeTerminalManager.isAwaitingInputPromptScreen(codexScreen))
  }

  @Test func awaitingInputSurvivesLatePromptRenderForCodex() async {
    // Regression: codex fires `PermissionRequest` before its prompt
    // UI has finished painting. The fingerprint at hook time is the
    // pre-prompt preamble; the next activity-poll sees the full
    // "Would you like to run …" block. Without the prompt-shape
    // guard the activity-poll misreads "prompt just rendered" as
    // "user moved on" and clears the chip ~2s after the hook.
    //
    // Driver leaves the initial screen empty so the screen-fallback
    // promotion path doesn't independently re-mark the awaiting
    // state — we want this test to exercise the activity-poll
    // re-baseline guard in isolation.
    await withMainSerialExecutor {
      await withDependencies {
        $0.date.now = Date(timeIntervalSince1970: 1234)
      } operation: {
        let clock = TestClock()
        let screenContents = LockIsolated("Running make build-app\n…")
        let server = AgentHookSocketServer(testingSocketPath: "/tmp/supacool-test-codex-awaiting-input")
        let manager = WorktreeTerminalManager(
          runtime: GhosttyRuntime(),
          socketServer: server,
          awaitingInputTTL: .seconds(8),
          awaitingInputTransitionOnDebounce: .milliseconds(250),
          awaitingInputTransitionOffDebounce: .milliseconds(250),
          awaitingInputActivityPollInterval: .seconds(1),
          clock: clock,
          readScreenContents: { _, _ in screenContents.value }
        )
        let worktree = makeWorktree()

        guard let tab = makeTab(in: manager, for: worktree) else {
          Issue.record("Expected tab and surface")
          return
        }
        let tabId = tab.tabId

        server.onNotification?(
          worktree.id,
          tabId.rawValue,
          tab.surfaceID,
          AgentHookNotification(
            agent: "codex",
            event: "PermissionRequest",
            title: nil,
            body: "make build-app",
            sessionID: nil
          )
        )
        await Task.yield()

        await clock.advance(by: .milliseconds(250))
        #expect(manager.isAwaitingInput(worktreeID: worktree.id, tabID: tabId))

        // Codex finishes rendering the prompt. Fingerprint diverges,
        // but the new screen still matches a known prompt shape — so
        // the activity-poll must re-baseline rather than clear.
        screenContents.setValue(
          """
          Would you like to run the following command?

          Reason: build the app

          |> make build-app

          1. Yes, proceed (y)
          2. Yes, and don't ask again for commands that start with `make build-app` (a)
          3. No, and tell Codex what to do differently (esc)

          Press enter to confirm or esc to cancel
          """
        )

        await clock.advance(by: .seconds(1))
        #expect(manager.isAwaitingInput(worktreeID: worktree.id, tabID: tabId))

        // Surface stays on the prompt — chip must remain.
        await clock.advance(by: .seconds(2))
        #expect(manager.isAwaitingInput(worktreeID: worktree.id, tabID: tabId))

        // User answers — surface no longer looks like a prompt; the
        // activity-poll's existing clear path takes over.
        screenContents.setValue("Approved. Running make build-app...\nbuilding…")

        await clock.advance(by: .milliseconds(750))
        #expect(manager.isAwaitingInput(worktreeID: worktree.id, tabID: tabId))

        await clock.advance(by: .milliseconds(250))
        #expect(!manager.isAwaitingInput(worktreeID: worktree.id, tabID: tabId))
      }
    }
  }

  @Test func awaitingInputClearsWhenTerminalOutputResumes() async {
    await withMainSerialExecutor {
      await withDependencies {
        $0.date.now = Date(timeIntervalSince1970: 1234)
      } operation: {
        let clock = TestClock()
        let screenContents = LockIsolated("Claude needs your permission\n1. Allow")
        let server = AgentHookSocketServer(testingSocketPath: "/tmp/supacool-test-clear-awaiting-input")
        let manager = WorktreeTerminalManager(
          runtime: GhosttyRuntime(),
          socketServer: server,
          awaitingInputTTL: .seconds(8),
          awaitingInputTransitionOnDebounce: .milliseconds(250),
          awaitingInputTransitionOffDebounce: .milliseconds(250),
          awaitingInputActivityPollInterval: .seconds(1),
          clock: clock,
          readScreenContents: { _, _ in screenContents.value }
        )
        let worktree = makeWorktree()

        guard let tab = makeTab(in: manager, for: worktree) else {
          Issue.record("Expected tab and surface")
          return
        }
        let tabId = tab.tabId

        server.onNotification?(
          worktree.id,
          tabId.rawValue,
          tab.surfaceID,
          AgentHookNotification(
            agent: "claude",
            event: "Notification",
            title: nil,
            body: "Claude needs your permission to use Bash",
            sessionID: nil
          )
        )
        await Task.yield()

        await clock.advance(by: .milliseconds(250))
        #expect(manager.isAwaitingInput(worktreeID: worktree.id, tabID: tabId))

        screenContents.setValue("Streaming output resumed\nEdited BoardRootView.swift")

        await clock.advance(by: .milliseconds(750))
        #expect(manager.isAwaitingInput(worktreeID: worktree.id, tabID: tabId))

        await clock.advance(by: .milliseconds(250))
        #expect(!manager.isAwaitingInput(worktreeID: worktree.id, tabID: tabId))
      }
    }
  }

  @Test func stableApprovalPromptScreenPromotesAwaitingInputWithoutHook() async {
    await withMainSerialExecutor {
      await withDependencies {
        $0.date.now = Date(timeIntervalSince1970: 1234)
      } operation: {
        let clock = TestClock()
        let screenContents = LockIsolated(
          """
          Do you want to make this edit to e2e-no-silent-failures.md?
          1. Yes
          2. Yes, and allow Claude to edit its own settings for this session
          3. No

          Esc to cancel  Tab to amend
          """
        )
        let manager = WorktreeTerminalManager(
          runtime: GhosttyRuntime(),
          awaitingInputTTL: .seconds(8),
          awaitingInputTransitionOnDebounce: .milliseconds(250),
          awaitingInputTransitionOffDebounce: .milliseconds(250),
          awaitingInputActivityPollInterval: .seconds(1),
          startPromptScreenScanning: false,
          clock: clock,
          readScreenContents: { _, _ in screenContents.value }
        )
        let worktree = makeWorktree()

        guard let tab = makeTab(in: manager, for: worktree) else {
          Issue.record("Expected tab and surface")
          return
        }
        let tabId = tab.tabId

        await manager.sampleAwaitingInputPromptScreensForTesting()
        #expect(!manager.isAwaitingInput(worktreeID: worktree.id, tabID: tabId))

        await manager.sampleAwaitingInputPromptScreensForTesting()
        manager.commitAwaitingInputPresentationForTesting(tabID: tabId, desiredState: true)
        #expect(manager.isAwaitingInput(worktreeID: worktree.id, tabID: tabId))

        screenContents.setValue("Waiting for the next instruction")

        manager.sampleAwaitingInputActivityForTesting(tabID: tabId)
        #expect(manager.isAwaitingInput(worktreeID: worktree.id, tabID: tabId))

        manager.commitAwaitingInputPresentationForTesting(tabID: tabId, desiredState: false)
        #expect(!manager.isAwaitingInput(worktreeID: worktree.id, tabID: tabId))
      }
    }
  }

  @Test func busyTransitionBeforeDebounceSuppressesAwaitingInputBadge() async {
    await withDependencies {
      $0.date.now = Date(timeIntervalSince1970: 1234)
    } operation: {
      let clock = TestClock()
      let server = AgentHookSocketServer(testingSocketPath: "/tmp/supacool-test-busy-suppresses-awaiting-input")
      let manager = WorktreeTerminalManager(
        runtime: GhosttyRuntime(),
        socketServer: server,
        awaitingInputTTL: .seconds(8),
        awaitingInputTransitionOnDebounce: .milliseconds(250),
        awaitingInputTransitionOffDebounce: .milliseconds(250),
        awaitingInputActivityPollInterval: .seconds(1),
        clock: clock
      )
      let worktree = makeWorktree()

      guard let tab = makeTab(in: manager, for: worktree) else {
        Issue.record("Expected tab and surface")
        return
      }
      let tabId = tab.tabId

      server.onNotification?(
        worktree.id,
        tabId.rawValue,
        tab.surfaceID,
        AgentHookNotification(
          agent: "claude",
          event: "Notification",
          title: nil,
          body: "Claude needs your permission to use Bash",
          sessionID: nil
        )
      )
      await Task.yield()
      server.onBusy?(worktree.id, tabId.rawValue, tab.surfaceID, true, nil)

      await clock.advance(by: .seconds(1))
      #expect(!manager.isAwaitingInput(worktreeID: worktree.id, tabID: tabId))
    }
  }

  /// Regression for the card stuck in "In Progress" (trace
  /// 3683DFE7…): Claude goes busy, then fires its idle "waiting for
  /// your input" Notification *without* a preceding Stop / busy=false
  /// edge. The busy latch is set only by hook edges, so unless an
  /// awaiting-input hook implies not-busy the latch stays stuck on and
  /// `classify` pins the card green forever. An awaiting-input hook must
  /// release the busy latch immediately, and the card must NOT fall back
  /// to busy after the awaiting lease's TTL expires.
  @Test func awaitingInputHookClearsStuckBusyLatch() async {
    await withMainSerialExecutor {
      await withDependencies {
        $0.date.now = Date(timeIntervalSince1970: 1234)
      } operation: {
        let clock = TestClock()
        let server = AgentHookSocketServer(testingSocketPath: "/tmp/supacool-test-awaiting-clears-busy")
        let manager = WorktreeTerminalManager(
          runtime: GhosttyRuntime(),
          socketServer: server,
          awaitingInputTTL: .seconds(8),
          awaitingInputTransitionOnDebounce: .milliseconds(250),
          awaitingInputTransitionOffDebounce: .milliseconds(250),
          awaitingInputActivityPollInterval: .seconds(1),
          clock: clock
        )
        let worktree = makeWorktree()

        guard let tab = makeTab(in: manager, for: worktree) else {
          Issue.record("Expected tab and surface")
          return
        }
        let tabId = tab.tabId

        // Agent working: busy latched on by a PreToolUse-style hook.
        server.onBusy?(worktree.id, tabId.rawValue, tab.surfaceID, true, 60594)
        #expect(manager.isAgentBusy(worktreeID: worktree.id, tabID: tabId))

        // Claude's idle "waiting for input" notification — no Stop and
        // no busy=false edge precedes it.
        server.onNotification?(
          worktree.id,
          tabId.rawValue,
          tab.surfaceID,
          AgentHookNotification(
            agent: "claude",
            event: "Notification",
            title: nil,
            body: "Claude is waiting for your input",
            sessionID: nil
          )
        )
        await Task.yield()

        // The awaiting hook releases the busy latch immediately.
        #expect(!manager.isAgentBusy(worktreeID: worktree.id, tabID: tabId))

        // Chip presents after the on-debounce; still not busy.
        await clock.advance(by: .milliseconds(250))
        #expect(manager.isAwaitingInput(worktreeID: worktree.id, tabID: tabId))
        #expect(!manager.isAgentBusy(worktreeID: worktree.id, tabID: tabId))

        // Lease holds until the TTL.
        await clock.advance(by: .seconds(7) + .milliseconds(750))
        #expect(manager.isAwaitingInput(worktreeID: worktree.id, tabID: tabId))

        // After the lease expires the card must stay out of "In
        // Progress": neither awaiting nor busy.
        await clock.advance(by: .milliseconds(250))
        #expect(!manager.isAwaitingInput(worktreeID: worktree.id, tabID: tabId))
        #expect(!manager.isAgentBusy(worktreeID: worktree.id, tabID: tabId))
      }
    }
  }

  /// Regression for the codex card stuck in "In Progress" (trace
  /// 0073F07A…): codex latches busy via UserPromptSubmit/PreToolUse
  /// hooks, then ends its turn with a `Stop` notification. The matching
  /// busy=0 progress hook fires on the *same* Stop event, but when it
  /// races, is dropped, or carries a stale `SUPACODE_*` env guard, only
  /// the Stop notification lands — and the busy latch stays stuck on,
  /// pinning the card green forever. A `Stop` notification must release
  /// the busy latch on its own. Unlike an awaiting-input hook, Stop is
  /// "turn finished" (not "blocked on user"), so the card falls through
  /// to "Waiting" rather than presenting a "Wants Input" chip.
  @Test func codexStopHookClearsStuckBusyLatch() async {
    await withMainSerialExecutor {
      await withDependencies {
        $0.date.now = Date(timeIntervalSince1970: 1234)
      } operation: {
        let clock = TestClock()
        let server = AgentHookSocketServer(testingSocketPath: "/tmp/supacool-test-stop-clears-busy")
        let manager = WorktreeTerminalManager(
          runtime: GhosttyRuntime(),
          socketServer: server,
          awaitingInputTTL: .seconds(8),
          awaitingInputTransitionOnDebounce: .milliseconds(250),
          awaitingInputTransitionOffDebounce: .milliseconds(250),
          awaitingInputActivityPollInterval: .seconds(1),
          clock: clock
        )
        let worktree = makeWorktree()

        guard let tab = makeTab(in: manager, for: worktree) else {
          Issue.record("Expected tab and surface")
          return
        }
        let tabId = tab.tabId

        // Agent working: busy latched on by a PreToolUse-style hook.
        server.onBusy?(worktree.id, tabId.rawValue, tab.surfaceID, true, 7964)
        #expect(manager.isAgentBusy(worktreeID: worktree.id, tabID: tabId))

        // Codex ends its turn with a Stop notification — no preceding
        // busy=false edge (the busy=0 progress hook never reached us).
        server.onNotification?(
          worktree.id,
          tabId.rawValue,
          tab.surfaceID,
          AgentHookNotification(
            agent: "codex",
            event: "Stop",
            title: "Done",
            body: "All complete",
            sessionID: nil
          )
        )
        await Task.yield()

        // Stop releases the busy latch immediately…
        #expect(!manager.isAgentBusy(worktreeID: worktree.id, tabID: tabId))
        // …without promoting to a "Wants Input" awaiting chip.
        await clock.advance(by: .seconds(1))
        #expect(!manager.isAwaitingInput(worktreeID: worktree.id, tabID: tabId))
        #expect(!manager.isAgentBusy(worktreeID: worktree.id, tabID: tabId))
      }
    }
  }

  /// Regression for the codex card stuck "Working" for hours (trace
  /// DF73B24A…): a split-pane codex agent latched busy via
  /// UserPromptSubmit/PreToolUse, then dropped *every* end-of-turn edge —
  /// no `busy=0`, no `Stop` notification at all — while its process stayed
  /// alive. The Stop/awaiting paths never fire (no hook), the PID-death
  /// sweep skips it (alive), and hooked tabs are excluded from the
  /// screen-fallback scan, so nothing recovers the latch. The stuck-busy
  /// watchdog clears it once the screen has been byte-stable across the
  /// staleness window.
  @Test func stuckBusyWatchdogClearsLatchWhenAliveAgentGoesSilentWithStableScreen() async {
    await withMainSerialExecutor {
      await withDependencies {
        $0.date.now = Date(timeIntervalSince1970: 1234)
      } operation: {
        let clock = TestClock()
        // A frozen "finished turn" screen — the codex prompt, unchanging.
        let screenContents = LockIsolated("› \n  (idle)")
        let server = AgentHookSocketServer(testingSocketPath: "/tmp/supacool-test-stuck-busy-watchdog")
        let manager = WorktreeTerminalManager(
          runtime: GhosttyRuntime(),
          socketServer: server,
          // PID never dies — the death sweep must NOT be what saves us.
          stuckBusyStaleSweepThreshold: 2,
          isProcessAlive: { _ in true },
          clock: clock,
          readScreenContents: { _, _ in screenContents.value }
        )
        let worktree = makeWorktree()

        guard let tab = makeTab(in: manager, for: worktree) else {
          Issue.record("Expected tab and surface")
          return
        }
        let tabId = tab.tabId

        // Agent working: busy latched on by a PreToolUse-style hook.
        server.onBusy?(worktree.id, tabId.rawValue, tab.surfaceID, true, 4242)
        #expect(manager.isAgentBusy(worktreeID: worktree.id, tabID: tabId))

        // Sweep 1 only seeds the baseline fingerprint — still busy.
        await manager.sweepAgentPIDs()
        #expect(manager.isAgentBusy(worktreeID: worktree.id, tabID: tabId))

        // Sweep 2: one stable sweep (staleSweeps == 1 < threshold) — busy.
        await manager.sweepAgentPIDs()
        #expect(manager.isAgentBusy(worktreeID: worktree.id, tabID: tabId))

        // Sweep 3: staleSweeps reaches the threshold — latch cleared.
        await manager.sweepAgentPIDs()
        #expect(!manager.isAgentBusy(worktreeID: worktree.id, tabID: tabId))
        // Not a "Wants Input" promotion — the agent finished, it isn't blocked.
        #expect(!manager.isAwaitingInput(worktreeID: worktree.id, tabID: tabId))
      }
    }
  }

  /// A legitimately long, quiet tool run (one busy hook, then silence while
  /// a command churns) must NOT be cleared: its screen keeps changing, so
  /// the watchdog's stability gate never trips even though the busy hook is
  /// long stale and the PID is alive. This is the case a plain TTL would
  /// get wrong — hence the screen-stability gate.
  @Test func stuckBusyWatchdogKeepsLatchWhileScreenKeepsChanging() async {
    await withMainSerialExecutor {
      await withDependencies {
        $0.date.now = Date(timeIntervalSince1970: 1234)
      } operation: {
        let clock = TestClock()
        let frame = LockIsolated(0)
        let screenContents = LockIsolated("build log line 0")
        let server = AgentHookSocketServer(testingSocketPath: "/tmp/supacool-test-stuck-busy-changing")
        let manager = WorktreeTerminalManager(
          runtime: GhosttyRuntime(),
          socketServer: server,
          stuckBusyStaleSweepThreshold: 2,
          isProcessAlive: { _ in true },
          clock: clock,
          readScreenContents: { _, _ in screenContents.value }
        )
        let worktree = makeWorktree()

        guard let tab = makeTab(in: manager, for: worktree) else {
          Issue.record("Expected tab and surface")
          return
        }
        let tabId = tab.tabId

        server.onBusy?(worktree.id, tabId.rawValue, tab.surfaceID, true, 4242)
        #expect(manager.isAgentBusy(worktreeID: worktree.id, tabID: tabId))

        // Many sweeps, but the screen advances each time → never stable.
        for _ in 0..<6 {
          frame.withValue { $0 += 1 }
          screenContents.setValue("build log line \(frame.value)")
          await manager.sweepAgentPIDs()
          #expect(manager.isAgentBusy(worktreeID: worktree.id, tabID: tabId))
        }
      }
    }
  }

  /// A fresh busy hook mid-window recreates the PID registration and resets
  /// the staleness counter, so the watchdog's clock restarts — an agent
  /// that keeps signalling work is never spuriously cleared.
  @Test func stuckBusyWatchdogResetsAfterAFreshBusyHook() async {
    await withMainSerialExecutor {
      await withDependencies {
        $0.date.now = Date(timeIntervalSince1970: 1234)
      } operation: {
        let clock = TestClock()
        let screenContents = LockIsolated("› \n  (idle)")
        let server = AgentHookSocketServer(testingSocketPath: "/tmp/supacool-test-stuck-busy-reset")
        let manager = WorktreeTerminalManager(
          runtime: GhosttyRuntime(),
          socketServer: server,
          stuckBusyStaleSweepThreshold: 2,
          isProcessAlive: { _ in true },
          clock: clock,
          readScreenContents: { _, _ in screenContents.value }
        )
        let worktree = makeWorktree()

        guard let tab = makeTab(in: manager, for: worktree) else {
          Issue.record("Expected tab and surface")
          return
        }
        let tabId = tab.tabId

        server.onBusy?(worktree.id, tabId.rawValue, tab.surfaceID, true, 4242)

        // Seed + one stable sweep — one short of clearing.
        await manager.sweepAgentPIDs()
        await manager.sweepAgentPIDs()
        #expect(manager.isAgentBusy(worktreeID: worktree.id, tabID: tabId))

        // A fresh busy hook arrives — the agent is still working. This
        // recreates the registration (staleSweeps back to 0).
        server.onBusy?(worktree.id, tabId.rawValue, tab.surfaceID, true, 4242)

        // The very next sweep would have cleared a stale latch; here it
        // only re-seeds, so the card stays busy.
        await manager.sweepAgentPIDs()
        #expect(manager.isAgentBusy(worktreeID: worktree.id, tabID: tabId))
      }
    }
  }

  /// Codex auto-approve round-trip (PermissionRequest → ~400ms →
  /// PreToolUse busyOn) must not produce a visible "Wants Input"
  /// blink. Guarded by the 750ms default on-debounce.
  @Test func codexAutoApproveRoundTripDoesNotFlickerAwaitingInputBadge() async {
    await withDependencies {
      $0.date.now = Date(timeIntervalSince1970: 1234)
    } operation: {
      let clock = TestClock()
      let server = AgentHookSocketServer(testingSocketPath: "/tmp/supacool-test-codex-auto-approve")
      let manager = WorktreeTerminalManager(
        runtime: GhosttyRuntime(),
        socketServer: server,
        awaitingInputTTL: .seconds(8),
        // Use production defaults for the presentation debounces so this
        // test pins the actual shipping behavior.
        awaitingInputActivityPollInterval: .seconds(1),
        clock: clock
      )
      let worktree = makeWorktree()

      guard let tab = makeTab(in: manager, for: worktree) else {
        Issue.record("Expected tab and surface")
        return
      }
      let tabId = tab.tabId

      // Codex: PermissionRequest then auto-approved PreToolUse ~400ms later.
      server.onNotification?(
        worktree.id,
        tabId.rawValue,
        tab.surfaceID,
        AgentHookNotification(
          agent: "codex",
          event: "PermissionRequest",
          title: nil,
          body: "approve shell escalation?",
          sessionID: nil
        )
      )
      await Task.yield()
      await clock.advance(by: .milliseconds(400))
      // Before on-debounce fires, the busy signal arrives and clears
      // the awaiting lease. The chip must never become visible.
      server.onBusy?(worktree.id, tabId.rawValue, tab.surfaceID, true, nil)
      await clock.advance(by: .milliseconds(500))

      #expect(!manager.isAwaitingInput(worktreeID: worktree.id, tabID: tabId))
    }
  }

  @Test func deferredWorkStopKeepsSessionInProgressUntilLeaseExpires() async {
    await withMainSerialExecutor {
      await withDependencies {
        $0.date.now = Date(timeIntervalSince1970: 1234)
      } operation: {
        let clock = TestClock()
        let server = AgentHookSocketServer(testingSocketPath: "/tmp/supacool-test-deferred-work")
        let manager = WorktreeTerminalManager(
          runtime: GhosttyRuntime(),
          socketServer: server,
          deferredWorkLeaseBuffer: .seconds(1),
          clock: clock
        )
        let worktree = makeWorktree()

        guard let tab = makeTab(in: manager, for: worktree) else {
          Issue.record("Expected tab and surface")
          return
        }
        let tabId = tab.tabId

        server.onNotification?(
          worktree.id,
          tabId.rawValue,
          tab.surfaceID,
          AgentHookNotification(
            agent: "claude",
            event: "Stop",
            title: nil,
            body: "Will iterate on next 409 in ~7 min.",
            sessionID: nil
          )
        )

        #expect(manager.isDeferredWorkActive(worktreeID: worktree.id, tabID: tabId))
        await Task.yield()

        await clock.advance(by: .seconds(7 * 60))
        #expect(manager.isDeferredWorkActive(worktreeID: worktree.id, tabID: tabId))

        await clock.advance(by: .seconds(1))
        #expect(!manager.isDeferredWorkActive(worktreeID: worktree.id, tabID: tabId))
      }
    }
  }

  @Test func finalStopClearsDeferredWorkLease() {
    withMainSerialExecutor {
      withDependencies {
        $0.date.now = Date(timeIntervalSince1970: 1234)
      } operation: {
        let clock = TestClock()
        let server = AgentHookSocketServer(testingSocketPath: "/tmp/supacool-test-final-stop")
        let manager = WorktreeTerminalManager(
          runtime: GhosttyRuntime(),
          socketServer: server,
          deferredWorkFallbackTTL: .seconds(60),
          clock: clock
        )
        let worktree = makeWorktree()

        guard let tab = makeTab(in: manager, for: worktree) else {
          Issue.record("Expected tab and surface")
          return
        }
        let tabId = tab.tabId

        server.onNotification?(
          worktree.id,
          tabId.rawValue,
          tab.surfaceID,
          AgentHookNotification(
            agent: "claude",
            event: "Stop",
            title: nil,
            body: "Watching in background. I'll report when complete.",
            sessionID: nil
          )
        )
        #expect(manager.isDeferredWorkActive(worktreeID: worktree.id, tabID: tabId))

        server.onNotification?(
          worktree.id,
          tabId.rawValue,
          tab.surfaceID,
          AgentHookNotification(
            agent: "claude",
            event: "Stop",
            title: nil,
            body: "Done. PR #2516 review fixes shipped.",
            sessionID: nil
          )
        )

        #expect(!manager.isDeferredWorkActive(worktreeID: worktree.id, tabID: tabId))
      }
    }
  }

  /// Regression for trace BF99621E (04:49): an evaluator holding for CI
  /// took (should take) a deferred-work lease, then Claude's built-in 60s
  /// idle reminder fired. The reminder used to clear the lease and promote
  /// the card to "Wants Input" mid-hold. The soft idle reminder must now
  /// be absorbed by an active lease, while a hard permission prompt still
  /// promotes and clears the lease.
  @Test func idleReminderDuringDeferredWorkLeaseDoesNotPromoteAwaitingInput() async {
    await withMainSerialExecutor {
      await withDependencies {
        $0.date.now = Date(timeIntervalSince1970: 1234)
      } operation: {
        let clock = TestClock()
        let server = AgentHookSocketServer(
          testingSocketPath: "/tmp/supacool-test-idle-reminder-deferred"
        )
        let manager = WorktreeTerminalManager(
          runtime: GhosttyRuntime(),
          socketServer: server,
          awaitingInputTransitionOnDebounce: .milliseconds(250),
          deferredWorkFallbackTTL: .seconds(60),
          clock: clock
        )
        let worktree = makeWorktree()

        guard let tab = makeTab(in: manager, for: worktree) else {
          Issue.record("Expected tab and surface")
          return
        }
        let tabId = tab.tabId

        // Evaluator-style Stop: holding for CI with a background poller.
        server.onNotification?(
          worktree.id,
          tabId.rawValue,
          tab.surfaceID,
          AgentHookNotification(
            agent: "claude",
            event: "Stop",
            title: nil,
            body: "evaluator: iter 3, step_8 waiting on live CI for PR #4346 "
              + "with an active background poller in the doer — holding for "
              + "the doer's next yield.",
            sessionID: nil
          )
        )
        #expect(manager.isDeferredWorkActive(worktreeID: worktree.id, tabID: tabId))

        // Claude's 60s idle reminder lands mid-hold.
        server.onNotification?(
          worktree.id,
          tabId.rawValue,
          tab.surfaceID,
          AgentHookNotification(
            agent: "claude",
            event: "Notification",
            title: nil,
            body: "Claude is waiting for your input",
            sessionID: nil
          )
        )
        await Task.yield()
        await clock.advance(by: .milliseconds(250))

        // The reminder must not clobber the lease nor present the chip.
        #expect(manager.isDeferredWorkActive(worktreeID: worktree.id, tabID: tabId))
        #expect(!manager.isAwaitingInput(worktreeID: worktree.id, tabID: tabId))

        // A permission prompt stays authoritative: promotes to awaiting
        // and releases the lease.
        server.onNotification?(
          worktree.id,
          tabId.rawValue,
          tab.surfaceID,
          AgentHookNotification(
            agent: "claude",
            event: "Notification",
            title: nil,
            body: "Claude needs your permission to use Bash",
            sessionID: nil
          )
        )
        await Task.yield()
        await clock.advance(by: .milliseconds(250))
        #expect(!manager.isDeferredWorkActive(worktreeID: worktree.id, tabID: tabId))
        #expect(manager.isAwaitingInput(worktreeID: worktree.id, tabID: tabId))
      }
    }
  }

  @Test func markAllNotificationsReadEmitsUpdatedIndicatorCount() async {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    state.notifications = [
      makeNotification(isRead: false),
      makeNotification(isRead: true),
    ]

    let stream = manager.eventStream()
    var iterator = stream.makeAsyncIterator()

    let first = await iterator.next()
    state.markAllNotificationsRead()
    let second = await iterator.next()

    #expect(first == .notificationIndicatorChanged(count: 1))
    #expect(second == .notificationIndicatorChanged(count: 0))
    #expect(state.notifications.map(\.isRead) == [true, true])
  }

  @Test func markNotificationsReadOnlyAffectsMatchingSurface() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    let surfaceA = UUID()
    let surfaceB = UUID()

    state.notifications = [
      makeNotification(surfaceId: surfaceA, isRead: false),
      makeNotification(surfaceId: surfaceB, isRead: false),
      makeNotification(surfaceId: surfaceB, isRead: true),
    ]

    state.markNotificationsRead(forSurfaceID: surfaceB)

    let aNotifications = state.notifications.filter { $0.surfaceId == surfaceA }
    let bNotifications = state.notifications.filter { $0.surfaceId == surfaceB }

    #expect(aNotifications.map(\.isRead) == [false])
    #expect(bNotifications.map(\.isRead) == [true, true])
    #expect(manager.hasUnseenNotifications(for: worktree.id) == true)

    state.markNotificationsRead(forSurfaceID: surfaceA)

    #expect(manager.hasUnseenNotifications(for: worktree.id) == false)
  }

  @Test func setNotificationsDisabledMarksAllRead() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    state.notifications = [
      makeNotification(isRead: false),
      makeNotification(isRead: false),
    ]

    state.setNotificationsEnabled(false)

    #expect(state.notifications.map(\.isRead) == [true, true])
    #expect(manager.hasUnseenNotifications(for: worktree.id) == false)
  }

  @Test func dismissAllNotificationsClearsState() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    state.notifications = [
      makeNotification(isRead: false),
      makeNotification(isRead: true),
    ]

    state.dismissAllNotifications()

    #expect(state.notifications.isEmpty)
    #expect(manager.hasUnseenNotifications(for: worktree.id) == false)
  }

  @Test func blockingScriptCompletionReportsExitCodeFromCommandFinished() async {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let stream = manager.eventStream()

    manager.handleCommand(.runBlockingScript(worktree, kind: .archive, script: "sleep 10"))

    guard let state = manager.stateIfExists(for: worktree.id),
      let tabId = state.tabManager.selectedTabId,
      let surface = state.splitTree(for: tabId).root?.leftmostLeaf()
    else {
      Issue.record("Expected blocking script tab and surface")
      return
    }

    surface.bridge.onCommandFinished?(1)

    let event = await nextEvent(stream) { event in
      if case .blockingScriptCompleted = event {
        return true
      }
      return false
    }

    #expect(event == .blockingScriptCompleted(worktreeID: worktree.id, kind: .archive, exitCode: 1, tabId: tabId))
  }

  @Test func blockingScriptCompletionPassesNilExitCodeWhenCommandFinishedReportsNil() async {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let stream = manager.eventStream()

    manager.handleCommand(.runBlockingScript(worktree, kind: .archive, script: "sleep 10"))

    guard let state = manager.stateIfExists(for: worktree.id),
      let tabId = state.tabManager.selectedTabId,
      let surface = state.splitTree(for: tabId).root?.leftmostLeaf()
    else {
      Issue.record("Expected blocking script tab and surface")
      return
    }

    surface.bridge.onCommandFinished?(nil)

    let event = await nextEvent(stream) { event in
      if case .blockingScriptCompleted = event {
        return true
      }
      return false
    }

    #expect(event == .blockingScriptCompleted(worktreeID: worktree.id, kind: .archive, exitCode: nil, tabId: tabId))
  }

  @Test func blockingScriptCommandFinishedFollowedByChildExitDoesNotDoubleFire() async {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let stream = manager.eventStream()

    manager.handleCommand(.runBlockingScript(worktree, kind: .archive, script: "sleep 10"))

    guard let state = manager.stateIfExists(for: worktree.id),
      let tabId = state.tabManager.selectedTabId,
      let surface = state.splitTree(for: tabId).root?.leftmostLeaf()
    else {
      Issue.record("Expected blocking script tab and surface")
      return
    }

    // Normal flow: command finishes, then shell exits later.
    surface.bridge.onCommandFinished?(0)
    surface.bridge.onChildExited?(0)

    // First completion event should arrive.
    let event = await nextEvent(stream) { event in
      if case .blockingScriptCompleted = event {
        return true
      }
      return false
    }
    #expect(event == .blockingScriptCompleted(worktreeID: worktree.id, kind: .archive, exitCode: 0, tabId: tabId))

    // The child exit should NOT produce a second completion.
    #expect(!manager.isBlockingScriptRunning(kind: .archive, for: worktree.id))
  }

  @Test func blockingScriptChildExitWithoutCommandFinishedIsCancellation() async {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let stream = manager.eventStream()

    manager.handleCommand(.runBlockingScript(worktree, kind: .archive, script: "sleep 10"))

    guard let state = manager.stateIfExists(for: worktree.id),
      let tabId = state.tabManager.selectedTabId,
      let surface = state.splitTree(for: tabId).root?.leftmostLeaf()
    else {
      Issue.record("Expected blocking script tab and surface")
      return
    }

    surface.bridge.onChildExited?(1)

    let event = await nextEvent(stream) { event in
      if case .blockingScriptCompleted = event {
        return true
      }
      return false
    }

    #expect(event == .blockingScriptCompleted(worktreeID: worktree.id, kind: .archive, exitCode: nil, tabId: nil))
  }

  @Test func blockingScriptSignalBasedTerminationReportsImmediately() async {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let stream = manager.eventStream()

    manager.handleCommand(.runBlockingScript(worktree, kind: .archive, script: "sleep 10"))

    guard let state = manager.stateIfExists(for: worktree.id),
      let tabId = state.tabManager.selectedTabId,
      let surface = state.splitTree(for: tabId).root?.leftmostLeaf()
    else {
      Issue.record("Expected blocking script tab and surface")
      return
    }

    // Ctrl+C sends exit code 130 (128 + SIGINT=2) via COMMAND_FINISHED.
    // Completion should fire immediately without waiting for onChildExited.
    surface.bridge.onCommandFinished?(130)

    let event = await nextEvent(stream) { event in
      if case .blockingScriptCompleted = event {
        return true
      }
      return false
    }

    #expect(event == .blockingScriptCompleted(worktreeID: worktree.id, kind: .archive, exitCode: 130, tabId: tabId))
  }

  @Test func blockingScriptRerunClosesOldTabWithoutFiringCompletion() async {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let stream = manager.eventStream()

    manager.handleCommand(.runBlockingScript(worktree, kind: .archive, script: "sleep 10"))

    guard let state = manager.stateIfExists(for: worktree.id),
      let firstTabId = state.tabManager.selectedTabId
    else {
      Issue.record("Expected first blocking script tab")
      return
    }

    // Re-run the same kind — old tab should close silently.
    manager.handleCommand(.runBlockingScript(worktree, kind: .archive, script: "sleep 10"))

    guard let secondTabId = state.tabManager.selectedTabId else {
      Issue.record("Expected second blocking script tab")
      return
    }

    #expect(firstTabId != secondTabId)
    #expect(!state.tabManager.tabs.map(\.id).contains(firstTabId))

    // Complete the second script — only this one should fire.
    guard let surface = state.splitTree(for: secondTabId).root?.leftmostLeaf() else {
      Issue.record("Expected surface for second tab")
      return
    }
    surface.bridge.onCommandFinished?(0)

    let event = await nextEvent(stream) { event in
      if case .blockingScriptCompleted = event {
        return true
      }
      return false
    }

    #expect(event == .blockingScriptCompleted(worktreeID: worktree.id, kind: .archive, exitCode: 0, tabId: secondTabId))
  }

  @Test func blockingScriptTabClosedManuallyReportsCancellation() async {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let stream = manager.eventStream()

    manager.handleCommand(.runBlockingScript(worktree, kind: .archive, script: "sleep 10"))

    guard let state = manager.stateIfExists(for: worktree.id),
      let tabId = state.tabManager.selectedTabId
    else {
      Issue.record("Expected blocking script tab")
      return
    }

    // Simulate user closing the tab.
    state.closeTab(tabId)

    let event = await nextEvent(stream) { event in
      if case .blockingScriptCompleted = event {
        return true
      }
      return false
    }

    #expect(event == .blockingScriptCompleted(worktreeID: worktree.id, kind: .archive, exitCode: nil, tabId: nil))
  }

  @Test func closeAllSurfacesCancelsPendingBlockingScripts() async {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let stream = manager.eventStream()

    manager.handleCommand(.runBlockingScript(worktree, kind: .archive, script: "sleep 10"))

    guard let state = manager.stateIfExists(for: worktree.id) else {
      Issue.record("Expected worktree state")
      return
    }

    state.closeAllSurfaces()

    let event = await nextEvent(stream) { event in
      if case .blockingScriptCompleted = event {
        return true
      }
      return false
    }

    #expect(event == .blockingScriptCompleted(worktreeID: worktree.id, kind: .archive, exitCode: nil, tabId: nil))
  }

  @Test func blockingScriptSuccessKeepsTabOpen() async {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let stream = manager.eventStream()

    manager.handleCommand(.runBlockingScript(worktree, kind: .archive, script: "sleep 10"))

    guard let state = manager.stateIfExists(for: worktree.id),
      let tabId = state.tabManager.selectedTabId,
      let surface = state.splitTree(for: tabId).root?.leftmostLeaf()
    else {
      Issue.record("Expected blocking script tab and surface")
      return
    }

    #expect(state.tabManager.tabs.map(\.id).contains(tabId))

    surface.bridge.onCommandFinished?(0)

    let event = await nextEvent(stream) { event in
      if case .blockingScriptCompleted = event {
        return true
      }
      return false
    }

    #expect(event == .blockingScriptCompleted(worktreeID: worktree.id, kind: .archive, exitCode: 0, tabId: tabId))
    // Tab stays open so the user can inspect output.
    #expect(state.tabManager.tabs.map(\.id).contains(tabId))
  }

  @Test func runScriptBlockingScriptTracksRunningState() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()

    #expect(manager.isBlockingScriptRunning(kind: .run, for: worktree.id) == false)

    manager.handleCommand(.runBlockingScript(worktree, kind: .run, script: "sleep 10"))

    #expect(manager.isBlockingScriptRunning(kind: .run, for: worktree.id) == true)
  }

  @Test func stopRunScriptClosesRunTab() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()

    manager.handleCommand(.runBlockingScript(worktree, kind: .run, script: "sleep 10"))
    #expect(manager.isBlockingScriptRunning(kind: .run, for: worktree.id) == true)

    manager.handleCommand(.stopRunScript(worktree))
    #expect(manager.isBlockingScriptRunning(kind: .run, for: worktree.id) == false)
  }

  @Test func runScriptTabTitleResetsAfterSignalInterruption() async {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let stream = manager.eventStream()

    manager.handleCommand(.runBlockingScript(worktree, kind: .run, script: "sleep 10"))

    guard let state = manager.stateIfExists(for: worktree.id),
      let tabId = state.tabManager.selectedTabId,
      let surface = state.splitTree(for: tabId).root?.leftmostLeaf()
    else {
      Issue.record("Expected run script tab and surface")
      return
    }

    let tab = state.tabManager.tabs.first { $0.id == tabId }
    #expect(tab?.title == "Run Script")
    #expect(tab?.isTitleLocked == true)
    #expect(tab?.tintColor == .green)

    // Simulate Ctrl+C (SIGINT = exit code 130).
    surface.bridge.onCommandFinished?(130)

    // Wait for completion event.
    _ = await nextEvent(stream) { event in
      if case .blockingScriptCompleted = event { return true }
      return false
    }

    let updatedTab = state.tabManager.tabs.first { $0.id == tabId }
    #expect(updatedTab?.isTitleLocked == false)
    #expect(updatedTab?.icon == nil)
    #expect(updatedTab?.tintColor == nil)
  }

  @Test func blockingScriptTabTitleResetsAfterFailure() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()

    manager.handleCommand(.runBlockingScript(worktree, kind: .archive, script: "sleep 10"))

    guard let state = manager.stateIfExists(for: worktree.id),
      let tabId = state.tabManager.selectedTabId,
      let surface = state.splitTree(for: tabId).root?.leftmostLeaf()
    else {
      Issue.record("Expected blocking script tab and surface")
      return
    }

    let tab = state.tabManager.tabs.first { $0.id == tabId }
    #expect(tab?.title == "Archive Script")
    #expect(tab?.tintColor == .orange)

    // Tab appearance reset happens synchronously in completeBlockingScript.
    surface.bridge.onCommandFinished?(1)

    let updatedTab = state.tabManager.tabs.first { $0.id == tabId }
    #expect(updatedTab?.isTitleLocked == false)
    #expect(updatedTab?.icon == nil)
    #expect(updatedTab?.tintColor == nil)
  }

  @Test func selectTabWithValidIdChangesSelection() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()

    // Create two blocking script tabs so we have two tabs to switch between.
    manager.handleCommand(.runBlockingScript(worktree, kind: .archive, script: "sleep 10"))
    manager.handleCommand(.runBlockingScript(worktree, kind: .delete, script: "sleep 10"))

    guard let state = manager.stateIfExists(for: worktree.id) else {
      Issue.record("Expected worktree state")
      return
    }

    let tabIds = state.tabManager.tabs.map(\.id)
    guard tabIds.count >= 2 else {
      Issue.record("Expected at least two tabs")
      return
    }
    let firstTabId = tabIds[0]
    let secondTabId = tabIds[1]

    // Select the second tab first.
    manager.handleCommand(.selectTab(worktree, tabID: secondTabId))
    #expect(state.tabManager.selectedTabId == secondTabId)

    // Select the first tab.
    manager.handleCommand(.selectTab(worktree, tabID: firstTabId))
    #expect(state.tabManager.selectedTabId == firstTabId)
  }

  @Test func inputObservedAutoUnparksMatchingSession() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    let sessionID = UUID()
    var session = AgentSession(
      id: sessionID,
      repositoryID: worktree.id,
      worktreeID: worktree.id,
      agent: .claude,
      initialPrompt: "x"
    )
    session.parked = true
    @Shared(.agentSessions) var sessions: [AgentSession]
    $sessions.withLock { $0 = [session] }

    state.onInputObserved?(TerminalTabID(rawValue: sessionID), "x")

    #expect(sessions.first?.parked == false)
  }

  @Test func inputObservedNoOpForNonParkedSession() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    let sessionID = UUID()
    let session = AgentSession(
      id: sessionID,
      repositoryID: worktree.id,
      worktreeID: worktree.id,
      agent: .claude,
      initialPrompt: "x"
    )
    @Shared(.agentSessions) var sessions: [AgentSession]
    $sessions.withLock { $0 = [session] }
    let beforeActivity = sessions.first?.lastActivityAt

    state.onInputObserved?(TerminalTabID(rawValue: sessionID), "x")

    // Non-parked sessions stay untouched — lastActivityAt isn't bumped on
    // every keystroke, so a quiet user typing in a live terminal doesn't
    // generate write churn against the persisted shared store.
    #expect(sessions.first?.parked == false)
    #expect(sessions.first?.lastActivityAt == beforeActivity)
  }

  @Test func submittedInputMarksAgentSessionOptimisticallyBusy() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime(), startPromptScreenScanning: false)
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    let sessionID = UUID()
    let tabID = TerminalTabID(rawValue: sessionID)
    state.registerTestTab(tabID: sessionID)
    @Shared(.agentSessions) var sessions: [AgentSession]
    $sessions.withLock {
      $0 = [
        AgentSession(
          id: sessionID,
          repositoryID: worktree.id,
          worktreeID: worktree.id,
          agent: .pi,
          initialPrompt: "x",
        ),
      ]
    }

    state.onInputObserved?(tabID, "\r")

    #expect(manager.isAgentBusy(worktreeID: worktree.id, tabID: tabID))
  }

  @Test func initialSubmittedInputMarksAgentSessionOptimisticallyBusy() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime(), startPromptScreenScanning: false)
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    let sessionID = UUID()
    let tabID = TerminalTabID(rawValue: sessionID)
    state.registerTestTab(tabID: sessionID)
    @Shared(.agentSessions) var sessions: [AgentSession]
    $sessions.withLock {
      $0 = [
        AgentSession(
          id: sessionID,
          repositoryID: worktree.id,
          worktreeID: worktree.id,
          agent: .pi,
          initialPrompt: "x",
        ),
      ]
    }

    manager.markSubmittedInitialInputForTesting(
      worktreeID: worktree.id,
      tabID: tabID,
      initialInput: "pi --resume abc\r",
    )

    #expect(manager.isAgentBusy(worktreeID: worktree.id, tabID: tabID))
  }

  @Test func typedInputWithoutSubmissionDoesNotMarkOptimisticallyBusy() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime(), startPromptScreenScanning: false)
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    let sessionID = UUID()
    let tabID = TerminalTabID(rawValue: sessionID)
    state.registerTestTab(tabID: sessionID)
    @Shared(.agentSessions) var sessions: [AgentSession]
    $sessions.withLock {
      $0 = [
        AgentSession(
          id: sessionID,
          repositoryID: worktree.id,
          worktreeID: worktree.id,
          agent: .pi,
          initialPrompt: "x",
        ),
      ]
    }

    state.onInputObserved?(tabID, "hello")

    #expect(!manager.isAgentBusy(worktreeID: worktree.id, tabID: tabID))
  }

  @Test func authoritativeBusyFalseClearsOptimisticBusy() {
    let server = AgentHookSocketServer(testingSocketPath: "/tmp/supacool-test-optimistic-clear")
    let manager = WorktreeTerminalManager(
      runtime: GhosttyRuntime(),
      socketServer: server,
      startPromptScreenScanning: false,
    )
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    let sessionID = UUID()
    let tabID = TerminalTabID(rawValue: sessionID)
    let tab = state.registerTestTab(tabID: sessionID)
    @Shared(.agentSessions) var sessions: [AgentSession]
    $sessions.withLock {
      $0 = [
        AgentSession(
          id: sessionID,
          repositoryID: worktree.id,
          worktreeID: worktree.id,
          agent: .pi,
          initialPrompt: "x",
        ),
      ]
    }

    state.onInputObserved?(tabID, "\n")
    #expect(manager.isAgentBusy(worktreeID: worktree.id, tabID: tabID))

    server.onBusy?(worktree.id, tabID.rawValue, tab.surfaceID, false, 21955)

    #expect(!manager.isAgentBusy(worktreeID: worktree.id, tabID: tabID))
  }

  @Test func optimisticBusyExpiresIfHooksNeverArrive() async {
    let clock = TestClock()
    let manager = WorktreeTerminalManager(
      runtime: GhosttyRuntime(),
      optimisticBusyTTL: .seconds(5),
      startPromptScreenScanning: false,
      clock: clock,
    )
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    let sessionID = UUID()
    let tabID = TerminalTabID(rawValue: sessionID)
    state.registerTestTab(tabID: sessionID)
    @Shared(.agentSessions) var sessions: [AgentSession]
    $sessions.withLock {
      $0 = [
        AgentSession(
          id: sessionID,
          repositoryID: worktree.id,
          worktreeID: worktree.id,
          agent: .pi,
          initialPrompt: "x",
        ),
      ]
    }

    state.onInputObserved?(tabID, "\n")
    #expect(manager.isAgentBusy(worktreeID: worktree.id, tabID: tabID))

    await Task.yield()
    await clock.advance(by: .seconds(5))
    await Task.yield()

    #expect(!manager.isAgentBusy(worktreeID: worktree.id, tabID: tabID))
  }

  @Test func firstHookDeadmanFiresWhenNoHooksArrive() async {
    let clock = TestClock()
    let manager = WorktreeTerminalManager(
      runtime: GhosttyRuntime(),
      optimisticBusyTTL: .seconds(60),
      firstHookDeadmanDelay: .seconds(10),
      startPromptScreenScanning: false,
      clock: clock,
      readScreenContents: { _, _ in "shell prompt captured by deadman" },
    )
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    let sessionID = UUID()
    let tabID = TerminalTabID(rawValue: sessionID)
    state.registerTestTab(tabID: sessionID)
    @Shared(.agentSessions) var sessions: [AgentSession]
    $sessions.withLock {
      $0 = [
        AgentSession(
          id: sessionID,
          repositoryID: worktree.id,
          worktreeID: worktree.id,
          agent: .claude,
          initialPrompt: "fix CEN-4841",
        ),
      ]
    }

    manager.scheduleFirstHookDeadmanForTesting(worktreeID: worktree.id, tabID: tabID)

    await Task.yield()
    await clock.advance(by: .seconds(10))
    await Task.yield()

    #expect(manager.firstHookDeadmanFireCount == 1)
  }

  @Test func firstHookDeadmanIsCancelledWhenHookArrivesFirst() async {
    let socket = AgentHookSocketServer(testingSocketPath: "/tmp/supacool-test-deadman-cancel")
    let clock = TestClock()
    let manager = WorktreeTerminalManager(
      runtime: GhosttyRuntime(),
      socketServer: socket,
      optimisticBusyTTL: .seconds(60),
      firstHookDeadmanDelay: .seconds(10),
      startPromptScreenScanning: false,
      clock: clock,
      readScreenContents: { _, _ in "should not be read" },
    )
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    let sessionID = UUID()
    let tabID = TerminalTabID(rawValue: sessionID)
    let tab = state.registerTestTab(tabID: sessionID)
    @Shared(.agentSessions) var sessions: [AgentSession]
    $sessions.withLock {
      $0 = [
        AgentSession(
          id: sessionID,
          repositoryID: worktree.id,
          worktreeID: worktree.id,
          agent: .claude,
          initialPrompt: "fix CEN-4841",
        ),
      ]
    }

    manager.scheduleFirstHookDeadmanForTesting(worktreeID: worktree.id, tabID: tabID)
    socket.onBusy?(worktree.id, tabID.rawValue, tab.surfaceID, true, 12345)

    await Task.yield()
    await clock.advance(by: .seconds(10))
    await Task.yield()

    #expect(manager.firstHookDeadmanFireCount == 0)
  }

  @Test func firstHookDeadmanIgnoresShellSessions() async {
    let clock = TestClock()
    let manager = WorktreeTerminalManager(
      runtime: GhosttyRuntime(),
      firstHookDeadmanDelay: .seconds(10),
      startPromptScreenScanning: false,
      clock: clock,
      readScreenContents: { _, _ in "should not be read" },
    )
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    let sessionID = UUID()
    let tabID = TerminalTabID(rawValue: sessionID)
    state.registerTestTab(tabID: sessionID)
    @Shared(.agentSessions) var sessions: [AgentSession]
    $sessions.withLock {
      $0 = [
        AgentSession(
          id: sessionID,
          repositoryID: worktree.id,
          worktreeID: worktree.id,
          agent: nil,
          initialPrompt: "",
        ),
      ]
    }

    manager.scheduleFirstHookDeadmanForTesting(worktreeID: worktree.id, tabID: tabID)

    await Task.yield()
    await clock.advance(by: .seconds(10))
    await Task.yield()

    #expect(manager.firstHookDeadmanFireCount == 0)
  }

  @Test func firstHookDeadmanContextStringFormatsDuration() {
    #expect(
      WorktreeTerminalManager.firstHookDeadmanContext(for: .seconds(10))
        == "no agent hook within 10s"
    )
    #expect(
      WorktreeTerminalManager.firstHookDeadmanContext(for: .seconds(30))
        == "no agent hook within 30s"
    )
  }

  @Test func selectTabWithStaleIdIsNoOp() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()

    manager.handleCommand(.runBlockingScript(worktree, kind: .archive, script: "sleep 10"))

    guard let state = manager.stateIfExists(for: worktree.id),
      let tabId = state.tabManager.selectedTabId
    else {
      Issue.record("Expected blocking script tab")
      return
    }

    // Close the tab, then try to select it by its stale ID.
    state.closeTab(tabId)
    let selectedBefore = state.tabManager.selectedTabId

    manager.handleCommand(.selectTab(worktree, tabID: tabId))

    // Selection should not change.
    #expect(state.tabManager.selectedTabId == selectedBefore)
  }

  private func makeTab(
    in manager: WorktreeTerminalManager,
    for worktree: Worktree
  ) -> (tabId: TerminalTabID, surfaceID: UUID)? {
    let state = manager.state(for: worktree)
    return state.registerTestTab()
  }

  private func makeWorktree(id: String = "/tmp/repo/wt-1") -> Worktree {
    let name = URL(fileURLWithPath: id).lastPathComponent
    return Worktree(
      id: id,
      name: name,
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: id),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
  }

  private func nextEvent(
    _ stream: AsyncStream<TerminalClient.Event>,
    matching predicate: (TerminalClient.Event) -> Bool
  ) async -> TerminalClient.Event? {
    for await event in stream where predicate(event) {
      return event
    }
    return nil
  }

  private func makeNotification(
    surfaceId: UUID = UUID(),
    isRead: Bool
  ) -> WorktreeTerminalNotification {
    WorktreeTerminalNotification(
      surfaceId: surfaceId,
      title: "Title",
      body: "Body",
      isRead: isRead
    )
  }

  private func makeLayoutSnapshot() -> TerminalLayoutSnapshot {
    TerminalLayoutSnapshot(
      tabs: [
        TerminalLayoutSnapshot.TabSnapshot(
          id: nil,
          title: "Terminal 1",
          icon: nil,
          tintColor: nil,
          layout: .leaf(
            TerminalLayoutSnapshot.SurfaceSnapshot(
              id: nil,
              workingDirectory: "/tmp/repo/wt-1"
            )
          ),
          focusedLeafIndex: 0
        ),
      ],
      selectedTabIndex: 0
    )
  }
}
