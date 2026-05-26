import AppKit
import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import Supacool

@MainActor
// `@Shared(.trashedSessions)` is process-global; the trash + removeSession
// tests both mutate it and would race when Swift Testing parallelizes them.
// Serialize the whole suite — precedent: `AppFeatureDeeplinkTests`.
@Suite(.serialized)
struct BoardFeatureTests {
  // MARK: - Session CRUD

  @Test(.dependencies) func createSessionAddsToListAndFocuses() async {
    struct NoInference: Error {}
    let store = TestStore(initialState: BoardFeature.State()) {
      BoardFeature()
    } withDependencies: {
      // createSession kicks off a background LLM call to refine the
      // display name; stub it out here so the effect terminates without
      // dispatching a follow-up action that would fail the exhaustivity
      // check.
      $0.backgroundInferenceClient.infer = { _, _ in throw NoInference() }
    }
    let session = Self.sampleSession()

    // createSession intentionally does NOT focus the new card — the user
    // stays on the board and sees it appear in "In Progress."
    await store.send(.createSession(session)) {
      $0.$sessions.withLock { $0 = [session] }
      $0.trayCards = [Self.sessionCreatingCard(for: session)]
    }
  }

  @Test(.dependencies) func createSessionRefinesDisplayNameViaInference() async {
    let store = TestStore(initialState: BoardFeature.State()) {
      BoardFeature()
    } withDependencies: {
      $0.backgroundInferenceClient.infer = { _, _ in "Fix Failing Unit Tests" }
    }
    let session = Self.sampleSession()  // prompt: "Fix the failing tests" → derived "Fix the failing tests"
    let sessionID = session.id

    await store.send(.createSession(session)) {
      $0.$sessions.withLock { $0 = [session] }
      $0.trayCards = [Self.sessionCreatingCard(for: session)]
    }
    await store.receive(\._autoDisplayNameSuggested) {
      $0.$sessions.withLock { sessions in
        sessions[0].displayName = "Fix Failing Unit Tests"
      }
    }
    _ = sessionID
  }

  @Test(.dependencies) func createSessionKeepsPinnedDisplayNameDespiteInference() async {
    let store = TestStore(initialState: BoardFeature.State()) {
      BoardFeature()
    } withDependencies: {
      $0.backgroundInferenceClient.infer = { _, _ in "LLM Generated Name" }
    }
    // Pin a custom displayName up front (simulates the PR-URL flow
    // setting "PR #42: Fix the widget"). The inference result must NOT
    // clobber it.
    let session = Self.sampleSession(displayName: "PR #42: Fix the widget")
    await store.send(.createSession(session)) {
      $0.$sessions.withLock { $0 = [session] }
      $0.trayCards = [Self.sessionCreatingCard(for: session)]
    }
    // No _autoDisplayNameSuggested is expected — the effect short-circuits
    // before calling infer because displayName != deriveDisplayName(prompt).
  }

  // MARK: - References

  /// PR refresh used to be triggered directly by `.cardAppeared`. That
  /// dispatch path was removed when we moved to a single global
  /// `_runPRRefreshTick` scheduler (architectural fix for the
  /// per-session × per-cardAppeared spawn storm), so this test now
  /// exercises the tick path instead.
  ///
  /// Uses a `TestClock` for `\.continuousClock` so the timeout-arm
  /// `clock.sleep(...)` inside `fetchPRWithTimeout` parks forever and
  /// the mocked `viewPullRequest` (which returns synchronously) is
  /// guaranteed to win the TaskGroup race.
  @Test(.dependencies) func prRefreshTickResolvesUnresolvedPullRequests() async {
    let ref = SessionReference.pullRequest(owner: "acme", repo: "widgets", number: 42, state: nil)
    var session = Self.sampleSession()
    session.references = [ref]
    session.referencesScannedAt = Date()
    let state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }
    let lookups = LockIsolated<[String]>([])
    let testClock = TestClock()
    let store = TestStore(initialState: state) {
      BoardFeature()
    } withDependencies: {
      $0.continuousClock = testClock
      $0.date = .constant(Date())
      $0.githubCLI.viewPullRequest = { owner, repo, number in
        lookups.withValue { $0.append("\(owner)/\(repo)#\(number)") }
        return .open
      }
    }
    store.exhaustivity = .off

    await store.send(._runPRRefreshTick)
    await store.skipReceivedActions()
    await store.finish()

    #expect(lookups.value.count == 1)
    #expect(lookups.value.first == "acme/widgets#42")
    #expect(
      store.state.sessions.first?.references == [
        .pullRequest(owner: "acme", repo: "widgets", number: 42, state: .open)
      ]
    )
  }

  @Test(.dependencies) func prRefreshTickUpdatesCachedOpenPullRequests() async {
    let ref = SessionReference.pullRequest(owner: "acme", repo: "widgets", number: 42, state: .open)
    var session = Self.sampleSession()
    session.references = [ref]
    session.referencesScannedAt = Date()
    let state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }
    let lookups = LockIsolated<[String]>([])
    let testClock = TestClock()
    let store = TestStore(initialState: state) {
      BoardFeature()
    } withDependencies: {
      $0.continuousClock = testClock
      $0.date = .constant(Date())
      $0.githubCLI.viewPullRequest = { owner, repo, number in
        lookups.withValue { $0.append("\(owner)/\(repo)#\(number)") }
        return .closed
      }
    }
    store.exhaustivity = .off

    await store.send(._runPRRefreshTick)
    await store.skipReceivedActions()
    await store.finish()

    #expect(lookups.value == ["acme/widgets#42"])
    #expect(store.state.sessions.first?.references == [
      .pullRequest(owner: "acme", repo: "widgets", number: 42, state: .closed)
    ])
  }

  @Test(.dependencies) func prRefreshTickSkipsRecentlyRefreshedPullRequests() async {
    let now = Date(timeIntervalSince1970: 1_000)
    let ref = SessionReference.pullRequest(owner: "acme", repo: "widgets", number: 42, state: .open)
    var session = Self.sampleSession()
    session.references = [ref]
    var state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }
    state.prRefreshSuccessAt[ref.dedupeKey] = now
    let lookups = LockIsolated<[String]>([])
    let store = TestStore(initialState: state) {
      BoardFeature()
    } withDependencies: {
      $0.date = .constant(now.addingTimeInterval(10))
      $0.githubCLI.viewPullRequest = { owner, repo, number in
        lookups.withValue { $0.append("\(owner)/\(repo)#\(number)") }
        return .closed
      }
    }

    await store.send(._runPRRefreshTick)

    #expect(lookups.value.isEmpty)
  }

  /// `.cardAppeared` still drives the transcript scan + ref merge; only
  /// the PR fetch moved to the global tick. So a cardAppeared on a
  /// session with no prior scan should pick up scanner-supplied refs
  /// and merge them in; PR state stays `nil` because no tick has run.
  @Test(.dependencies) func cardAppearedMergesPromptAndTerminalTranscriptReferences() async {
    var session = Self.sampleSession()
    session.references = []
    session.referencesScannedAt = nil
    let state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }
    let store = TestStore(initialState: state) {
      BoardFeature()
    } withDependencies: {
      $0.sessionReferenceScannerClient.scanText = { _ in [.ticket(id: "CEN-10")] }
      $0.sessionReferenceScannerClient.scanTerminalTranscript = { _ in [
        .pullRequest(owner: "acme", repo: "widgets", number: 42, state: nil),
      ] }
    }
    store.exhaustivity = .off

    await store.send(.cardAppeared(id: session.id))
    await store.skipReceivedActions()

    #expect(store.state.sessions.first?.references == [
      .ticket(id: "CEN-10"),
      .pullRequest(owner: "acme", repo: "widgets", number: 42, state: nil),
    ])
  }

  /// Once the tick runs after the scan, the PR fanout should populate
  /// state on the same session (and any other session referencing it).
  /// This is the dedupe-across-sessions invariant the global scheduler
  /// was introduced for.
  @Test(.dependencies) func prRefreshTickFansOutAcrossSessionsReferencingTheSamePR() async {
    let ref = SessionReference.pullRequest(owner: "acme", repo: "widgets", number: 42, state: nil)
    var s1 = Self.sampleSession()
    s1.references = [ref]
    s1.referencesScannedAt = Date()
    var s2 = Self.sampleSession(id: UUID(uuidString: "00000000-0000-0000-0000-000000000099")!)
    s2.references = [ref]
    s2.referencesScannedAt = Date()
    let state = BoardFeature.State()
    state.$sessions.withLock { $0 = [s1, s2] }
    let lookups = LockIsolated<[String]>([])
    let testClock = TestClock()
    let store = TestStore(initialState: state) {
      BoardFeature()
    } withDependencies: {
      $0.continuousClock = testClock
      $0.date = .constant(Date())
      $0.githubCLI.viewPullRequest = { owner, repo, number in
        lookups.withValue { $0.append("\(owner)/\(repo)#\(number)") }
        return .merged
      }
    }
    store.exhaustivity = .off

    await store.send(._runPRRefreshTick)
    await store.skipReceivedActions()
    await store.finish()

    // Only ONE network round-trip even though TWO sessions reference
    // the PR.
    #expect(lookups.value.count == 1)
    // Both sessions get the new state.
    for session in store.state.sessions {
      #expect(session.references == [
        .pullRequest(owner: "acme", repo: "widgets", number: 42, state: .merged)
      ])
    }
  }

  @Test(.dependencies) func renameSessionUpdatesDisplayName() async {
    let session = Self.sampleSession(displayName: "Old Name")
    let state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }

    let store = TestStore(initialState: state) {
      BoardFeature()
    }

    await store.send(.renameSession(id: session.id, newName: "  New Name  ")) {
      $0.$sessions.withLock { sessions in
        sessions[0].displayName = "New Name"
      }
    }
  }

  @Test(.dependencies) func renameSessionIgnoresEmptyName() async {
    let session = Self.sampleSession(displayName: "Keep Me")
    let state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }

    let store = TestStore(initialState: state) {
      BoardFeature()
    }

    // Whitespace-only rename should be a no-op.
    await store.send(.renameSession(id: session.id, newName: "   "))
  }

  @Test(.dependencies) func togglePriorityFlipsPersistedBit() async {
    let session = Self.sampleSession()
    let state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }

    let store = TestStore(initialState: state) {
      BoardFeature()
    }

    await store.send(.togglePriority(id: session.id)) {
      $0.$sessions.withLock { $0[0].isPriority = true }
    }

    await store.send(.togglePriority(id: session.id)) {
      $0.$sessions.withLock { $0[0].isPriority = false }
    }
  }

  @Test(.dependencies) func parkSessionMarksParkedDestroysTabAndReleasesOwnedProcesses() async throws {
    let now = Date(timeIntervalSince1970: 1_750_000_111)
    let transition = Date(timeIntervalSince1970: 1_750_000_000)
    var session = Self.sampleSession()
    session.updatePrimaryTerminal {
      $0.lastKnownBusy = true
      $0.lastBusyTransitionAt = transition
    }
    let repo = Repository(
      id: session.repositoryID,
      rootURL: URL(fileURLWithPath: session.repositoryID),
      name: "Repo",
      worktrees: []
    )
    let sentCommands = LockIsolated<[TerminalClient.Command]>([])
    var state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }
    state.focusedSessionID = session.id

    let store = TestStore(initialState: state) {
      BoardFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.terminalClient.send = { command in
        sentCommands.withValue { $0.append(command) }
      }
    }

    await store.send(.parkSession(id: session.id, repositories: [repo])) {
      $0.$sessions.withLock { sessions in
        sessions[0].parked = true
        sessions[0].updatePrimaryTerminal {
          $0.lastKnownBusy = false
          $0.lastBusyTransitionAt = nil
          $0.lastActivityAt = now
        }
      }
      $0.focusedSessionID = nil
    }
    await store.finish()

    let commands = sentCommands.value
    #expect(commands.count == 2)
    let destroyCommand = try #require(commands.first)
    guard case .destroyTab(let worktree, let tabID) = destroyCommand else {
      Issue.record("Expected destroyTab command, got \(destroyCommand)")
      return
    }
    #expect(tabID.rawValue == session.id)
    #expect(worktree.id == session.worktreeID)
    #expect(
      commands.dropFirst().first == .releaseOwnedProcesses(worktreePath: session.currentWorkspacePath)
    )
  }

  @Test(.dependencies) func parkSessionKeepsOwnedProcessesWhenSiblingStillUnparked() async throws {
    let now = Date(timeIntervalSince1970: 1_750_000_111)
    let session = Self.sampleSession(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
      worktreeID: "/tmp/repo/wt"
    )
    let sibling = Self.sampleSession(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
      worktreeID: session.worktreeID
    )
    let repo = Repository(
      id: session.repositoryID,
      rootURL: URL(fileURLWithPath: session.repositoryID),
      name: "Repo",
      worktrees: []
    )
    let sentCommands = LockIsolated<[TerminalClient.Command]>([])
    let state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session, sibling] }

    let store = TestStore(initialState: state) {
      BoardFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.terminalClient.send = { command in
        sentCommands.withValue { $0.append(command) }
      }
    }

    await store.send(.parkSession(id: session.id, repositories: [repo])) {
      $0.$sessions.withLock { sessions in
        sessions[0].parked = true
        sessions[0].updatePrimaryTerminal {
          $0.lastKnownBusy = false
          $0.lastBusyTransitionAt = nil
          $0.lastActivityAt = now
        }
      }
    }
    await store.finish()

    let commands = sentCommands.value
    #expect(commands.count == 1)
    guard case .destroyTab = try #require(commands.first) else {
      Issue.record("Expected only destroyTab command, got \(commands)")
      return
    }
  }

  @Test(.dependencies)
  func parkActiveSessionMarksParkedAndReleasesOwnedProcessesWithoutDestroyingTab() async throws {
    let now = Date(timeIntervalSince1970: 1_750_000_222)
    let transition = Date(timeIntervalSince1970: 1_750_000_000)
    var session = Self.sampleSession()
    session.updatePrimaryTerminal {
      $0.lastKnownBusy = true
      $0.lastBusyTransitionAt = transition
    }
    let sentCommands = LockIsolated<[TerminalClient.Command]>([])
    var state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }
    state.focusedSessionID = session.id

    let store = TestStore(initialState: state) {
      BoardFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.terminalClient.send = { command in
        sentCommands.withValue { $0.append(command) }
      }
    }

    await store.send(.parkActiveSession(id: session.id)) {
      $0.$sessions.withLock { sessions in
        sessions[0].parked = true
        sessions[0].parkedActive = true
        sessions[0].updatePrimaryTerminal { $0.lastActivityAt = now }
      }
      $0.focusedSessionID = nil
    }

    await store.finish()

    #expect(store.state.sessions[0].lastKnownBusy)
    #expect(store.state.sessions[0].lastBusyTransitionAt == transition)
    #expect(
      sentCommands.value == [.releaseOwnedProcesses(worktreePath: session.currentWorkspacePath)]
    )
  }

  @Test(.dependencies) func unparkSessionClearsParkedAndStandbyBits() async {
    let now = Date(timeIntervalSince1970: 1_750_000_333)
    var session = Self.sampleSession()
    session.parked = true
    session.parkedActive = true
    session.updatePrimaryTerminal { $0.lastKnownBusy = true }
    var state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }
    state.focusedSessionID = session.id

    let store = TestStore(initialState: state) {
      BoardFeature()
    } withDependencies: {
      $0.date = .constant(now)
    }

    await store.send(.unparkSession(id: session.id)) {
      $0.$sessions.withLock { sessions in
        sessions[0].parked = false
        sessions[0].parkedActive = false
        sessions[0].updatePrimaryTerminal { $0.lastActivityAt = now }
      }
    }

    #expect(store.state.focusedSessionID == session.id)
    #expect(store.state.sessions[0].lastKnownBusy)
  }

  @Test(.dependencies) func serverLifecycleStatusRequestedRunsStatusScript() async {
    let repositoryID = "/tmp/repo-lifecycle-status-\(UUID().uuidString)"
    let worktreeID = "\(repositoryID)/wt"
    let session = Self.sampleSession(
      repositoryID: repositoryID,
      worktreeID: worktreeID,
      displayName: "API Server"
    )
    Self.configureServerLifecycle(
      repositoryID: repositoryID,
      statusScript: "status"
    )
    let state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }
    let calls = LockIsolated<[LifecycleCall]>([])

    let store = TestStore(initialState: state) {
      BoardFeature()
    } withDependencies: {
      $0.serverLifecycleClient.run = { worktree, kind, script, context in
        let actualWorktreeID = await MainActor.run { worktree.id }
        let actualWorkingDirectory = await MainActor.run {
          worktree.workingDirectory.path(percentEncoded: false)
        }
        #expect(actualWorktreeID == worktreeID)
        #expect(actualWorkingDirectory == worktreeID)
        calls.withValue {
          $0.append(LifecycleCall(kind: kind, script: script, context: context))
        }
        return ServerLifecycleScriptResult(exitCode: 0, stdout: "listening", stderr: "")
      }
    }

    await store.send(.serverLifecycleStatusRequested(sessionID: session.id)) {
      $0.serverLifecycleByWorkspace[worktreeID] = BoardFeature.ServerLifecycleViewState(
        workspacePath: worktreeID,
        name: "Dev server",
        status: .checking,
        detail: nil
      )
    }
    await store.receive(
      ._serverLifecycleResponse(
        workspacePath: worktreeID,
        name: "Dev server",
        status: .running,
        detail: "listening"
      )
    ) {
      $0.serverLifecycleByWorkspace[worktreeID] = BoardFeature.ServerLifecycleViewState(
        workspacePath: worktreeID,
        name: "Dev server",
        status: .running,
        detail: "listening"
      )
    }

    #expect(
      calls.value == [
        LifecycleCall(
          kind: .status,
          script: "status",
          context: Self.lifecycleContext(for: session, event: "status")
        ),
      ]
    )
  }

  @Test(.dependencies) func serverLifecycleStartTappedRunsStartScriptWithManualEvent() async {
    let repositoryID = "/tmp/repo-lifecycle-start-\(UUID().uuidString)"
    let worktreeID = "\(repositoryID)/wt"
    let session = Self.sampleSession(
      repositoryID: repositoryID,
      worktreeID: worktreeID,
      displayName: "Web"
    )
    Self.configureServerLifecycle(
      repositoryID: repositoryID,
      startScript: "start"
    )
    let state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }
    let calls = LockIsolated<[LifecycleCall]>([])

    let store = TestStore(initialState: state) {
      BoardFeature()
    } withDependencies: {
      $0.serverLifecycleClient.run = { _, kind, script, context in
        calls.withValue {
          $0.append(LifecycleCall(kind: kind, script: script, context: context))
        }
        return ServerLifecycleScriptResult(exitCode: 0, stdout: "started", stderr: "")
      }
    }

    await store.send(.serverLifecycleStartTapped(sessionID: session.id)) {
      $0.serverLifecycleByWorkspace[worktreeID] = BoardFeature.ServerLifecycleViewState(
        workspacePath: worktreeID,
        name: "Dev server",
        status: .starting,
        detail: nil
      )
    }
    await store.receive(
      ._serverLifecycleResponse(
        workspacePath: worktreeID,
        name: "Dev server",
        status: .running,
        detail: "started"
      )
    ) {
      $0.serverLifecycleByWorkspace[worktreeID] = BoardFeature.ServerLifecycleViewState(
        workspacePath: worktreeID,
        name: "Dev server",
        status: .running,
        detail: "started"
      )
    }

    #expect(
      calls.value == [
        LifecycleCall(
          kind: .start,
          script: "start",
          context: Self.lifecycleContext(for: session, event: "manual_start")
        ),
      ]
    )
  }

  @Test(.dependencies) func removeSessionAutoStopsServerLifecycleWhenLastUnparkedSession() async {
    let repositoryID = "/tmp/repo-lifecycle-remove-\(UUID().uuidString)"
    let worktreeID = "\(repositoryID)/wt"
    let session = Self.sampleSession(
      repositoryID: repositoryID,
      worktreeID: worktreeID,
      displayName: "API"
    )
    Self.configureServerLifecycle(
      repositoryID: repositoryID,
      stopScript: "stop"
    )
    let state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }
    state.$trashedSessions.withLock { $0 = [] }
    let trashedAt = Date(timeIntervalSince1970: 1_750_000_000)
    let clock = TestClock()
    let calls = LockIsolated<[LifecycleCall]>([])

    let store = TestStore(initialState: state) {
      BoardFeature()
    } withDependencies: {
      $0.date = .constant(trashedAt)
      $0.serverLifecycleClient.run = { _, kind, script, context in
        calls.withValue {
          $0.append(LifecycleCall(kind: kind, script: script, context: context))
        }
        try await clock.sleep(for: .seconds(1))
        return ServerLifecycleScriptResult(exitCode: 0, stdout: "stopped", stderr: "")
      }
    }

    let expectedEntry = TrashedSession(
      session: session,
      repositoryID: repositoryID,
      worktreeID: worktreeID,
      deleteBackingWorktree: false,
      additionalWorktreeIDsToDelete: [],
      trashedAt: trashedAt
    )
    await store.send(.removeSession(id: session.id)) {
      $0.$sessions.withLock { $0 = [] }
      $0.$trashedSessions.withLock { $0 = [expectedEntry] }
      $0.serverLifecycleByWorkspace[worktreeID] = BoardFeature.ServerLifecycleViewState(
        workspacePath: worktreeID,
        name: "Dev server",
        status: .stopping,
        detail: nil
      )
    }
    await store.receive(
      .delegate(
        .sessionRemoved(
          sessionID: session.id,
          repositoryID: repositoryID,
          worktreeID: worktreeID,
          deleteBackingWorktree: false,
          additionalWorktreeIDsToDelete: []
        )
      )
    )
    await clock.advance(by: .seconds(1))
    await store.receive(
      ._serverLifecycleResponse(
        workspacePath: worktreeID,
        name: "Dev server",
        status: .stopped,
        detail: "stopped"
      )
    ) {
      $0.serverLifecycleByWorkspace[worktreeID] = BoardFeature.ServerLifecycleViewState(
        workspacePath: worktreeID,
        name: "Dev server",
        status: .stopped,
        detail: "stopped"
      )
    }

    #expect(
      calls.value == [
        LifecycleCall(
          kind: .stop,
          script: "stop",
          context: Self.lifecycleContext(for: session, event: "session_removed")
        ),
      ]
    )
  }

  @Test(.dependencies) func removeSessionDoesNotAutoStopServerLifecycleWhenSiblingStillUnparked() async {
    let repositoryID = "/tmp/repo-lifecycle-shared-\(UUID().uuidString)"
    let worktreeID = "\(repositoryID)/wt"
    let removed = Self.sampleSession(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
      repositoryID: repositoryID,
      worktreeID: worktreeID,
      displayName: "One"
    )
    let sibling = Self.sampleSession(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!,
      repositoryID: repositoryID,
      worktreeID: worktreeID,
      displayName: "Two"
    )
    Self.configureServerLifecycle(
      repositoryID: repositoryID,
      stopScript: "stop"
    )
    let state = BoardFeature.State()
    state.$sessions.withLock { $0 = [removed, sibling] }
    state.$trashedSessions.withLock { $0 = [] }
    let calls = LockIsolated<Int>(0)
    let trashedAt = Date(timeIntervalSince1970: 1_750_000_000)

    let store = TestStore(initialState: state) {
      BoardFeature()
    } withDependencies: {
      $0.date = .constant(trashedAt)
      $0.serverLifecycleClient.run = { _, _, _, _ in
        calls.withValue { $0 += 1 }
        return ServerLifecycleScriptResult(exitCode: 0, stdout: "", stderr: "")
      }
    }

    let expectedEntry = TrashedSession(
      session: removed,
      repositoryID: repositoryID,
      worktreeID: worktreeID,
      deleteBackingWorktree: false,
      additionalWorktreeIDsToDelete: [],
      trashedAt: trashedAt
    )
    await store.send(.removeSession(id: removed.id)) {
      $0.$sessions.withLock { $0 = [sibling] }
      $0.$trashedSessions.withLock { $0 = [expectedEntry] }
    }
    await store.receive(
      .delegate(
        .sessionRemoved(
          sessionID: removed.id,
          repositoryID: repositoryID,
          worktreeID: worktreeID,
          deleteBackingWorktree: false,
          additionalWorktreeIDsToDelete: []
        )
      )
    )
    await store.finish()

    #expect(calls.value == 0)
  }

  @Test(.dependencies) func parkSessionAutoStopsServerLifecycle() async throws {
    let repositoryID = "/tmp/repo-lifecycle-park-\(UUID().uuidString)"
    let worktreeID = "\(repositoryID)/wt"
    let session = Self.sampleSession(
      repositoryID: repositoryID,
      worktreeID: worktreeID,
      displayName: "Worker"
    )
    let repo = Repository(
      id: repositoryID,
      rootURL: URL(fileURLWithPath: repositoryID),
      name: "Repo",
      worktrees: []
    )
    Self.configureServerLifecycle(
      repositoryID: repositoryID,
      stopScript: "stop"
    )
    let state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }
    let now = Date(timeIntervalSince1970: 1_750_000_123)
    let clock = TestClock()
    let calls = LockIsolated<[LifecycleCall]>([])

    let store = TestStore(initialState: state) {
      BoardFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.serverLifecycleClient.run = { _, kind, script, context in
        calls.withValue {
          $0.append(LifecycleCall(kind: kind, script: script, context: context))
        }
        try await clock.sleep(for: .seconds(1))
        return ServerLifecycleScriptResult(exitCode: 0, stdout: "stopped", stderr: "")
      }
    }

    await store.send(.parkSession(id: session.id, repositories: [repo])) {
      $0.$sessions.withLock { sessions in
        sessions[0].parked = true
        sessions[0].updatePrimaryTerminal {
          $0.lastKnownBusy = false
          $0.lastBusyTransitionAt = nil
          $0.lastActivityAt = now
        }
      }
      $0.serverLifecycleByWorkspace[worktreeID] = BoardFeature.ServerLifecycleViewState(
        workspacePath: worktreeID,
        name: "Dev server",
        status: .stopping,
        detail: nil
      )
    }
    await clock.advance(by: .seconds(1))
    await store.receive(
      ._serverLifecycleResponse(
        workspacePath: worktreeID,
        name: "Dev server",
        status: .stopped,
        detail: "stopped"
      )
    ) {
      $0.serverLifecycleByWorkspace[worktreeID] = BoardFeature.ServerLifecycleViewState(
        workspacePath: worktreeID,
        name: "Dev server",
        status: .stopped,
        detail: "stopped"
      )
    }

    #expect(
      calls.value == [
        LifecycleCall(
          kind: .stop,
          script: "stop",
          context: Self.lifecycleContext(for: session, event: "parked")
        ),
      ]
    )
  }

  @Test(.dependencies) func unparkSessionAutoStartsServerLifecycle() async {
    let repositoryID = "/tmp/repo-lifecycle-unpark-\(UUID().uuidString)"
    let worktreeID = "\(repositoryID)/wt"
    var session = Self.sampleSession(
      repositoryID: repositoryID,
      worktreeID: worktreeID,
      displayName: "Worker"
    )
    session.parked = true
    Self.configureServerLifecycle(
      repositoryID: repositoryID,
      startScript: "start",
      autoStartOnUnpark: true
    )
    let state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }
    let now = Date(timeIntervalSince1970: 1_750_000_456)
    let clock = TestClock()
    let calls = LockIsolated<[LifecycleCall]>([])

    let store = TestStore(initialState: state) {
      BoardFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.serverLifecycleClient.run = { _, kind, script, context in
        calls.withValue {
          $0.append(LifecycleCall(kind: kind, script: script, context: context))
        }
        try await clock.sleep(for: .seconds(1))
        return ServerLifecycleScriptResult(exitCode: 0, stdout: "started", stderr: "")
      }
    }

    await store.send(.unparkSession(id: session.id)) {
      $0.$sessions.withLock { sessions in
        sessions[0].parked = false
        sessions[0].updatePrimaryTerminal { $0.lastActivityAt = now }
      }
      $0.serverLifecycleByWorkspace[worktreeID] = BoardFeature.ServerLifecycleViewState(
        workspacePath: worktreeID,
        name: "Dev server",
        status: .starting,
        detail: nil
      )
    }
    await clock.advance(by: .seconds(1))
    await store.receive(
      ._serverLifecycleResponse(
        workspacePath: worktreeID,
        name: "Dev server",
        status: .running,
        detail: "started"
      )
    ) {
      $0.serverLifecycleByWorkspace[worktreeID] = BoardFeature.ServerLifecycleViewState(
        workspacePath: worktreeID,
        name: "Dev server",
        status: .running,
        detail: "started"
      )
    }

    #expect(
      calls.value == [
        LifecycleCall(
          kind: .start,
          script: "start",
          context: Self.lifecycleContext(for: session, event: "unparked")
        ),
      ]
    )
  }

  @Test(.dependencies) func removeSessionDropsItAndClearsFocusIfFocused() async {
    let session = Self.sampleSession()
    var state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }
    state.focusedSessionID = session.id
    let trashedAt = Date(timeIntervalSince1970: 1_750_000_000)

    let store = TestStore(initialState: state) {
      BoardFeature()
    } withDependencies: {
      $0.date = .constant(trashedAt)
    }

    let expectedEntry = TrashedSession(
      session: session,
      repositoryID: session.repositoryID,
      worktreeID: session.worktreeID,
      deleteBackingWorktree: false,
      additionalWorktreeIDsToDelete: [],
      trashedAt: trashedAt
    )
    await store.send(.removeSession(id: session.id)) {
      $0.$sessions.withLock { $0 = [] }
      $0.$trashedSessions.withLock { $0 = [expectedEntry] }
      $0.focusedSessionID = nil
    }
    // Repo-root sessions have no backing worktree cleanup.
    await store.receive(
      .delegate(
        .sessionRemoved(
          sessionID: session.id,
          repositoryID: session.repositoryID,
          worktreeID: session.worktreeID,
          deleteBackingWorktree: false,
          additionalWorktreeIDsToDelete: []
        )
      )
    )
  }

  @Test(.dependencies) func removeSessionDeletesOwnedWorktreeImmediately() async {
    let session = Self.sampleSession(
      repositoryID: "/tmp/repo",
      worktreeID: "/tmp/repo/wt-1",
      removeBackingWorktreeOnDelete: true
    )
    let state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }
    let trashedAt = Date(timeIntervalSince1970: 1_750_000_000)

    let store = TestStore(initialState: state) {
      BoardFeature()
    } withDependencies: {
      $0.date = .constant(trashedAt)
    }

    let expectedEntry = TrashedSession(
      session: session,
      repositoryID: "/tmp/repo",
      worktreeID: "/tmp/repo/wt-1",
      deleteBackingWorktree: false,
      additionalWorktreeIDsToDelete: [],
      trashedAt: trashedAt
    )
    await store.send(.removeSession(id: session.id)) {
      $0.$sessions.withLock { $0 = [] }
      $0.$trashedSessions.withLock { $0 = [expectedEntry] }
    }
    await store.receive(
      .delegate(
        .sessionRemoved(
          sessionID: session.id,
          repositoryID: "/tmp/repo",
          worktreeID: "/tmp/repo/wt-1",
          deleteBackingWorktree: true,
          additionalWorktreeIDsToDelete: []
        )
      )
    )
  }

  @Test(.dependencies) func requestRemoveSessionChecksOwnedWorktreeAndProceedsWhenClean() async {
    let session = Self.sampleSession(
      repositoryID: "/tmp/repo",
      worktreeID: "/tmp/repo/wt-1",
      removeBackingWorktreeOnDelete: true
    )
    let state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }
    state.$trashedSessions.withLock { $0 = [] }
    let trashedAt = Date(timeIntervalSince1970: 1_750_000_000)

    let clock = TestClock()
    let store = TestStore(initialState: state) {
      BoardFeature()
    } withDependencies: {
      $0.date = .constant(trashedAt)
      $0.gitClient.statusPorcelain = { url in
        try await clock.sleep(for: .seconds(1))
        var path = url.path(percentEncoded: false)
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        #expect(path == "/tmp/repo/wt-1")
        return ""
      }
    }

    let expectedEntry = TrashedSession(
      session: session,
      repositoryID: "/tmp/repo",
      worktreeID: "/tmp/repo/wt-1",
      deleteBackingWorktree: false,
      additionalWorktreeIDsToDelete: [],
      trashedAt: trashedAt
    )
    await store.send(.requestRemoveSession(id: session.id))
    await clock.advance(by: .seconds(1))
    await store.receive(
      ._sessionRemovalDirtyCheckResponse(
        id: session.id,
        dirtyWorkspaces: [],
        checkFailures: []
      )
    ) {
      $0.$sessions.withLock { $0 = [] }
      $0.$trashedSessions.withLock { $0 = [expectedEntry] }
    }
    await store.receive(
      .delegate(
        .sessionRemoved(
          sessionID: session.id,
          repositoryID: "/tmp/repo",
          worktreeID: "/tmp/repo/wt-1",
          deleteBackingWorktree: true,
          additionalWorktreeIDsToDelete: []
        )
      )
    )
  }

  @Test(.dependencies) func requestRemoveSessionPromptsWhenOwnedWorktreeIsDirty() async {
    let session = Self.sampleSession(
      repositoryID: "/tmp/repo",
      worktreeID: "/tmp/repo/wt-1",
      removeBackingWorktreeOnDelete: true
    )
    let state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }
    state.$trashedSessions.withLock { $0 = [] }
    let trashedAt = Date(timeIntervalSince1970: 1_750_000_000)
    let dirtyWorkspace = BoardFeature.DirtyRemovalWorkspace(
      path: "/tmp/repo/wt-1",
      files: [
        ChangedFile(path: "Sources/App.swift", status: .modified),
        ChangedFile(path: "notes.md", status: .untracked),
      ]
    )

    let clock = TestClock()
    let store = TestStore(initialState: state) {
      BoardFeature()
    } withDependencies: {
      $0.date = .constant(trashedAt)
      $0.gitClient.statusPorcelain = { url in
        try await clock.sleep(for: .seconds(1))
        var path = url.path(percentEncoded: false)
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        #expect(path == "/tmp/repo/wt-1")
        return " M Sources/App.swift\0?? notes.md\0"
      }
    }

    let expectedConfirmation = BoardFeature.DirtySessionRemovalConfirmationState(
      sessionID: session.id,
      displayName: session.displayName,
      dirtyWorkspaces: [dirtyWorkspace],
      checkFailures: []
    )
    let expectedEntry = TrashedSession(
      session: session,
      repositoryID: "/tmp/repo",
      worktreeID: "/tmp/repo/wt-1",
      deleteBackingWorktree: false,
      additionalWorktreeIDsToDelete: [],
      trashedAt: trashedAt
    )

    await store.send(.requestRemoveSession(id: session.id))
    await clock.advance(by: .seconds(1))
    await store.receive(
      ._sessionRemovalDirtyCheckResponse(
        id: session.id,
        dirtyWorkspaces: [dirtyWorkspace],
        checkFailures: []
      )
    ) {
      $0.dirtySessionRemovalConfirmation = expectedConfirmation
    }
    await store.send(.confirmDirtySessionRemoval(id: session.id)) {
      $0.dirtySessionRemovalConfirmation = nil
      $0.$sessions.withLock { $0 = [] }
      $0.$trashedSessions.withLock { $0 = [expectedEntry] }
    }
    await store.receive(
      .delegate(
        .sessionRemoved(
          sessionID: session.id,
          repositoryID: "/tmp/repo",
          worktreeID: "/tmp/repo/wt-1",
          deleteBackingWorktree: true,
          additionalWorktreeIDsToDelete: []
        )
      )
    )
  }

  @Test(.dependencies) func removeSessionKeepsSharedOwnedWorktree() async {
    let worktreeID = "/tmp/repo/wt-1"
    let removed = Self.sampleSession(
      repositoryID: "/tmp/repo",
      worktreeID: worktreeID,
      removeBackingWorktreeOnDelete: true
    )
    let sibling = Self.sampleSession(
      repositoryID: "/tmp/repo",
      worktreeID: worktreeID,
      removeBackingWorktreeOnDelete: true
    )
    let state = BoardFeature.State()
    state.$sessions.withLock { $0 = [removed, sibling] }
    let trashedAt = Date(timeIntervalSince1970: 1_750_000_000)

    let store = TestStore(initialState: state) {
      BoardFeature()
    } withDependencies: {
      $0.date = .constant(trashedAt)
    }

    // Captured `deleteBackingWorktree=false` in trash because the
    // sibling session still references the same worktree at trash time.
    let expectedEntry = TrashedSession(
      session: removed,
      repositoryID: "/tmp/repo",
      worktreeID: worktreeID,
      deleteBackingWorktree: false,
      additionalWorktreeIDsToDelete: [],
      trashedAt: trashedAt
    )
    await store.send(.removeSession(id: removed.id)) {
      $0.$sessions.withLock { sessions in
        sessions = [sibling]
      }
      $0.$trashedSessions.withLock { $0 = [expectedEntry] }
    }
    await store.receive(
      .delegate(
        .sessionRemoved(
          sessionID: removed.id,
          repositoryID: "/tmp/repo",
          worktreeID: worktreeID,
          deleteBackingWorktree: false,
          additionalWorktreeIDsToDelete: []
        )
      )
    )
  }

  @Test(.dependencies) func removeSessionDeletesConvertedWorktreeImmediately() async {
    // A repo-root session that used the "convert to worktree" popover
    // has `worktreeID == repositoryID` but a divergent
    // `currentWorkspacePath`. The trash entry keeps recoverable card
    // metadata only; cleanup is dispatched immediately.
    let session = AgentSession(
      repositoryID: "/tmp/repo",
      worktreeID: "/tmp/repo",
      currentWorkspacePath: "/tmp/repo/worktrees/feature-x",
      agent: .claude,
      initialPrompt: "Work on feature X"
    )
    let state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }
    let trashedAt = Date(timeIntervalSince1970: 1_750_000_000)

    let store = TestStore(initialState: state) {
      BoardFeature()
    } withDependencies: {
      $0.date = .constant(trashedAt)
    }

    let expectedEntry = TrashedSession(
      session: session,
      repositoryID: "/tmp/repo",
      worktreeID: "/tmp/repo",
      deleteBackingWorktree: false,
      additionalWorktreeIDsToDelete: [],
      trashedAt: trashedAt
    )
    await store.send(.removeSession(id: session.id)) {
      $0.$sessions.withLock { $0 = [] }
      $0.$trashedSessions.withLock { $0 = [expectedEntry] }
    }
    await store.receive(
      .delegate(
        .sessionRemoved(
          sessionID: session.id,
          repositoryID: "/tmp/repo",
          worktreeID: "/tmp/repo",
          deleteBackingWorktree: false,
          additionalWorktreeIDsToDelete: ["/tmp/repo/worktrees/feature-x"]
        )
      )
    )
  }

  @Test(.dependencies) func removeSessionKeepsConvertedWorktreeIfSharedWithOtherSession() async {
    let convertedPath = "/tmp/repo/worktrees/shared-x"
    let converter = AgentSession(
      repositoryID: "/tmp/repo",
      worktreeID: "/tmp/repo",
      currentWorkspacePath: convertedPath,
      agent: .claude,
      initialPrompt: "Original"
    )
    let sibling = AgentSession(
      repositoryID: "/tmp/repo",
      worktreeID: convertedPath,
      agent: .claude,
      initialPrompt: "Sibling"
    )
    let state = BoardFeature.State()
    state.$sessions.withLock { $0 = [converter, sibling] }
    let trashedAt = Date(timeIntervalSince1970: 1_750_000_000)

    let store = TestStore(initialState: state) {
      BoardFeature()
    } withDependencies: {
      $0.date = .constant(trashedAt)
    }

    let expectedEntry = TrashedSession(
      session: converter,
      repositoryID: "/tmp/repo",
      worktreeID: "/tmp/repo",
      deleteBackingWorktree: false,
      additionalWorktreeIDsToDelete: [],
      trashedAt: trashedAt
    )
    await store.send(.removeSession(id: converter.id)) {
      $0.$sessions.withLock { $0 = [sibling] }
      $0.$trashedSessions.withLock { $0 = [expectedEntry] }
    }
    await store.receive(
      .delegate(
        .sessionRemoved(
          sessionID: converter.id,
          repositoryID: "/tmp/repo",
          worktreeID: "/tmp/repo",
          deleteBackingWorktree: false,
          additionalWorktreeIDsToDelete: []
        )
      )
    )
  }

  // MARK: - Trash flow

  @Test(.dependencies) func restoreFromTrashBringsSessionBack() async {
    let session = Self.sampleSession()
    let trashedAt = Date(timeIntervalSince1970: 1_750_000_000)
    let entry = TrashedSession(
      session: session,
      repositoryID: session.repositoryID,
      worktreeID: session.worktreeID,
      deleteBackingWorktree: true,
      additionalWorktreeIDsToDelete: [],
      trashedAt: trashedAt
    )
    let state = BoardFeature.State()
    state.$trashedSessions.withLock { $0 = [entry] }

    let store = TestStore(initialState: state) {
      BoardFeature()
    }

    await store.send(.restoreFromTrash(id: session.id)) {
      $0.$trashedSessions.withLock { $0 = [] }
      $0.$sessions.withLock { $0 = [session] }
    }
  }

  @Test(.dependencies) func deleteFromTrashFiresCapturedCleanup() async {
    let session = Self.sampleSession(
      repositoryID: "/tmp/repo",
      worktreeID: "/tmp/repo/wt-1",
      removeBackingWorktreeOnDelete: true
    )
    let trashedAt = Date(timeIntervalSince1970: 1_750_000_000)
    let entry = TrashedSession(
      session: session,
      repositoryID: "/tmp/repo",
      worktreeID: "/tmp/repo/wt-1",
      deleteBackingWorktree: true,
      additionalWorktreeIDsToDelete: ["/tmp/repo/extra"],
      trashedAt: trashedAt
    )
    let state = BoardFeature.State()
    state.$trashedSessions.withLock { $0 = [entry] }

    let store = TestStore(initialState: state) {
      BoardFeature()
    }

    await store.send(.deleteFromTrash(id: session.id)) {
      $0.$trashedSessions.withLock { $0 = [] }
    }
    await store.receive(
      .delegate(
        .sessionRemoved(
          sessionID: session.id,
          repositoryID: "/tmp/repo",
          worktreeID: "/tmp/repo/wt-1",
          deleteBackingWorktree: true,
          additionalWorktreeIDsToDelete: ["/tmp/repo/extra"]
        )
      )
    )
  }

  @Test(.dependencies) func sweepExpiredTrashRemovesEntriesPastWindow() async {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let fresh = Self.sampleSession()
    let stale = Self.sampleSession()
    let staleEntry = TrashedSession(
      session: stale,
      repositoryID: stale.repositoryID,
      worktreeID: stale.worktreeID,
      deleteBackingWorktree: false,
      additionalWorktreeIDsToDelete: [],
      // Trashed 4 days ago — past the 3-day window.
      trashedAt: now.addingTimeInterval(-4 * 24 * 60 * 60)
    )
    let freshEntry = TrashedSession(
      session: fresh,
      repositoryID: fresh.repositoryID,
      worktreeID: fresh.worktreeID,
      deleteBackingWorktree: false,
      additionalWorktreeIDsToDelete: [],
      trashedAt: now.addingTimeInterval(-1 * 24 * 60 * 60)
    )
    let state = BoardFeature.State()
    state.$trashedSessions.withLock { $0 = [staleEntry, freshEntry] }

    let store = TestStore(initialState: state) {
      BoardFeature()
    } withDependencies: {
      $0.date = .constant(now)
    }
    // Off-exhaustivity: sweep dispatches one .deleteFromTrash → one
    // .delegate.sessionRemoved → state mutations on @Shared trash.
    // Asserting the final state is enough; the precise interleaving
    // varies by .merge ordering.
    store.exhaustivity = .off

    await store.send(._sweepExpiredTrash)
    await store.receive(\.deleteFromTrash)
    await store.receive(\.delegate.sessionRemoved)
    #expect(store.state.trashedSessions.map(\.id) == [freshEntry.id])
  }

  @Test(.dependencies) func markCompletedOnceSetsFlag() async {
    let session = Self.sampleSession()
    let state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }

    let store = TestStore(initialState: state) {
      BoardFeature()
    }
    store.exhaustivity = .off

    await store.send(.markSessionCompletedOnce(id: session.id)) {
      $0.$sessions.withLock {
        $0[0].updatePrimaryTerminal { $0.hasCompletedAtLeastOnce = true }
      }
    }

    // Second call is a no-op — flag is already set and lastActivityAt stays.
    await store.send(.markSessionCompletedOnce(id: session.id))
  }

  @Test(.dependencies) func priorityTerminationPresentsAlertAndDelegates() async {
    let session = Self.sampleSession(displayName: "Deploy fix", isPriority: true)
    let alertID = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
    let state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }

    let store = TestStore(initialState: state) {
      BoardFeature()
    } withDependencies: {
      $0.uuid = .constant(alertID)
    }

    await store.send(.prioritySessionTerminated(id: session.id, status: .interrupted)) {
      $0.priorityTerminationAlert = BoardFeature.PriorityTerminationAlertState(
        id: alertID,
        sessionID: session.id,
        displayName: "Deploy fix",
        status: .interrupted
      )
    }
    await store.receive(
      .delegate(
        .prioritySessionTerminated(
          title: "Priority session terminated",
          body: "Deploy fix stopped while the agent was still working."
        )
      )
    )
  }

  @Test(.dependencies) func priorityTerminationIgnoresNonPrioritySessions() async {
    let session = Self.sampleSession(displayName: "Regular session", isPriority: false)
    let state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }

    let store = TestStore(initialState: state) {
      BoardFeature()
    }

    await store.send(.prioritySessionTerminated(id: session.id, status: .detached))
    #expect(store.state.priorityTerminationAlert == nil)
  }

  @Test(.dependencies) func setManualStatusOverridePersists() async {
    let session = Self.sampleSession()
    let state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }

    let store = TestStore(initialState: state) {
      BoardFeature()
    }

    await store.send(.setManualStatusOverride(id: session.id, status: .waitingOnMe)) {
      $0.$sessions.withLock { $0[0].manualStatusOverride = .waitingOnMe }
    }

    await store.send(.setManualStatusOverride(id: session.id, status: nil)) {
      $0.$sessions.withLock { $0[0].manualStatusOverride = nil }
    }
  }

  @Test(.dependencies) func busyTransitionClearsManualOverride() async {
    var session = Self.sampleSession()
    session.manualStatusOverride = .waitingOnMe
    let state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }

    let store = TestStore(initialState: state) {
      BoardFeature()
    }
    store.exhaustivity = .off

    await store.send(.updateSessionBusyState(id: session.id, busy: true)) {
      $0.$sessions.withLock { sessions in
        sessions[0].updatePrimaryTerminal { $0.lastKnownBusy = true }
        sessions[0].manualStatusOverride = nil
      }
    }
  }

  @Test(.dependencies) func updateSessionBusyStatePersistsTransitionTimestamp() async {
    let session = Self.sampleSession()
    let state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }

    let store = TestStore(initialState: state) {
      BoardFeature()
    }
    store.exhaustivity = .off

    await store.send(.updateSessionBusyState(id: session.id, busy: true)) {
      $0.$sessions.withLock { sessions in
        sessions[0].updatePrimaryTerminal { $0.lastKnownBusy = true }
        #expect(sessions[0].lastBusyTransitionAt != nil)
      }
    }

    await store.send(.updateSessionBusyState(id: session.id, busy: false)) {
      $0.$sessions.withLock { sessions in
        sessions[0].updatePrimaryTerminal { $0.lastKnownBusy = false }
        #expect(sessions[0].lastBusyTransitionAt != nil)
      }
    }
  }

  // MARK: - Focus

  @Test(.dependencies) func focusAndUnfocusSession() async {
    let target = UUID()
    let store = TestStore(initialState: BoardFeature.State()) {
      BoardFeature()
    }

    await store.send(.focusSession(id: target)) {
      $0.focusedSessionID = target
    }

    await store.send(.focusSession(id: nil)) {
      $0.focusedSessionID = nil
    }
  }

  // MARK: - Repo filter

  @Test(.dependencies) func toggleRepositoryAddsThenRemoves() async {
    let store = TestStore(initialState: BoardFeature.State()) {
      BoardFeature()
    }

    await store.send(.toggleRepository(id: "/tmp/repo")) {
      $0.$filters.withLock { $0.selectedRepositoryIDs = ["/tmp/repo"] }
    }

    await store.send(.toggleRepository(id: "/tmp/repo")) {
      $0.$filters.withLock { $0.selectedRepositoryIDs = [] }
    }
  }

  @Test(.dependencies) func showAllRepositoriesClearsFilter() async {
    let state = BoardFeature.State()
    state.$filters.withLock {
      $0.selectedRepositoryIDs = ["/tmp/a", "/tmp/b"]
    }

    let store = TestStore(initialState: state) {
      BoardFeature()
    }

    await store.send(.showAllRepositories) {
      $0.$filters.withLock { $0.selectedRepositoryIDs = [] }
    }
  }

  @Test(.dependencies) func focusRepositoryReplacesFilterWithSingleRepo() async {
    let state = BoardFeature.State()
    state.$filters.withLock {
      $0.selectedRepositoryIDs = ["/tmp/a", "/tmp/b"]
    }

    let store = TestStore(initialState: state) {
      BoardFeature()
    }

    await store.send(.focusRepository(id: "/tmp/c")) {
      $0.$filters.withLock { $0.selectedRepositoryIDs = ["/tmp/c"] }
    }
  }

  // MARK: - Visibility query

  @Test(.dependencies) func visibleSessionsFiltersByRepo() {
    let sessionA = Self.sampleSession(repositoryID: "/tmp/a")
    let sessionB = Self.sampleSession(repositoryID: "/tmp/b")
    let state = BoardFeature.State()
    state.$sessions.withLock { $0 = [sessionA, sessionB] }
    state.$filters.withLock { $0.selectedRepositoryIDs = ["/tmp/a"] }

    #expect(state.visibleSessions.map(\.id) == [sessionA.id])
    #expect(state.filters.includes(repositoryID: "/tmp/a"))
    #expect(!state.filters.includes(repositoryID: "/tmp/b"))
  }

  @Test(.dependencies) func visibleSessionsShowsAllWhenFilterEmpty() {
    let sessionA = Self.sampleSession(repositoryID: "/tmp/a")
    let sessionB = Self.sampleSession(repositoryID: "/tmp/b")
    let state = BoardFeature.State()
    state.$sessions.withLock { $0 = [sessionA, sessionB] }

    #expect(state.visibleSessions.count == 2)
    #expect(state.filters.showsAllRepositories)
  }

  // MARK: - Display name derivation

  @Test func deriveDisplayNameTakesFirstFewWords() {
    let id = UUID()
    let name = AgentSession.deriveDisplayName(
      from: "Fix the broken CI pipeline and add tests",
      fallbackID: id
    )
    #expect(name == "Fix the broken CI pipeline")
  }

  @Test func deriveDisplayNameFallsBackOnEmptyPrompt() {
    let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
    let name = AgentSession.deriveDisplayName(from: "", fallbackID: id)
    #expect(name == "Session 12345678")
  }

  @Test func deriveDisplayNameSanitizesPunctuation() {
    let id = UUID()
    let name = AgentSession.deriveDisplayName(
      from: "/c-nightly-regression, please!",
      fallbackID: id
    )
    // Punctuation is a separator; dash and underscore are preserved.
    #expect(name == "c-nightly-regression please")
  }

  // MARK: - Auto-Observer

  @Test(.dependencies) func toggleAutoObserverFlipsFlag() async {
    let session = Self.sampleSession()
    let state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }

    let store = TestStore(initialState: state) {
      BoardFeature()
    } withDependencies: {
      // Enabling fires an immediate autoObserverTriggered so the
      // observer can react to whatever's already on screen. With an
      // empty screen the effect short-circuits to a nil decision.
      $0.terminalClient.readScreenContents = { _, _ in nil }
    }

    await store.send(.toggleAutoObserver(id: session.id)) {
      $0.$sessions.withLock { $0[0].autoObserver = true }
    }
    await store.receive(.autoObserverTriggered(id: session.id)) {
      $0.autoObserverInFlight.insert(session.id)
    }
    await store.receive(._autoObserverDecided(id: session.id, response: nil)) {
      $0.autoObserverInFlight.remove(session.id)
    }
    // Disabling does not fire a trigger.
    await store.send(.toggleAutoObserver(id: session.id)) {
      $0.$sessions.withLock { $0[0].autoObserver = false }
    }
  }

  @Test(.dependencies) func toggleAutoObserverOnRespondsToCurrentScreen() async throws {
    // Mid-session: agent has paused on a permission prompt, user
    // toggles the observer ON. We should immediately read the screen
    // and respond — no need to wait for the next idle/awaiting-input
    // edge.
    let sessionID = UUID()
    let session = Self.sampleSession(id: sessionID)
    let state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }

    let store = TestStore(initialState: state) {
      BoardFeature()
    } withDependencies: {
      $0.terminalClient.readScreenContents = { _, _ in "Continue? (y/n)" }
      $0.terminalClient.send = { _ in }
      $0.autoObserverClient.decide = { _, _, _ in "y" }
    }

    await store.send(.toggleAutoObserver(id: sessionID)) {
      $0.$sessions.withLock { $0[0].autoObserver = true }
    }
    await store.receive(.autoObserverTriggered(id: sessionID)) {
      $0.autoObserverInFlight.insert(sessionID)
    }
    await store.receive(._autoObserverDecided(id: sessionID, response: "y")) {
      $0.autoObserverInFlight.remove(sessionID)
    }
  }

  @Test(.dependencies) func setAutoObserverPromptPersists() async {
    let session = Self.sampleSession()
    let state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }

    let store = TestStore(initialState: state) {
      BoardFeature()
    }

    await store.send(.setAutoObserverPrompt(id: session.id, prompt: "Allow all file edits")) {
      $0.$sessions.withLock { $0[0].autoObserverPrompt = "Allow all file edits" }
    }
  }

  @Test(.dependencies) func autoObserverTriggeredSkipsWhenDisabled() async {
    let session = Self.sampleSession()
    let state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }

    let store = TestStore(initialState: state) {
      BoardFeature()
    }

    // Session has autoObserver = false (default) → action is a no-op
    await store.send(.autoObserverTriggered(id: session.id))
  }

  @Test(.dependencies) func autoObserverTriggeredReadsScreenAndDecides() async throws {
    let sessionID = UUID()
    let session = Self.sampleSession(id: sessionID)
    var modifiedSession = session
    modifiedSession.autoObserver = true
    let state = BoardFeature.State()
    state.$sessions.withLock { $0 = [modifiedSession] }

    let store = TestStore(initialState: state) {
      BoardFeature()
    } withDependencies: {
      $0.terminalClient.readScreenContents = { _, _ in "Continue? (y/n)" }
      $0.terminalClient.send = { _ in }
      $0.autoObserverClient.decide = { _, _, _ in "y" }
    }

    await store.send(.autoObserverTriggered(id: sessionID)) {
      $0.autoObserverInFlight.insert(sessionID)
    }
    await store.receive(._autoObserverDecided(id: sessionID, response: "y")) {
      $0.autoObserverInFlight.remove(sessionID)
    }
  }

  @Test(.dependencies) func autoObserverSkipsWhenDecisionIsNil() async throws {
    let sessionID = UUID()
    var session = Self.sampleSession(id: sessionID)
    session.autoObserver = true
    let state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }

    let store = TestStore(initialState: state) {
      BoardFeature()
    } withDependencies: {
      $0.terminalClient.readScreenContents = { _, _ in "Some ambiguous output" }
      $0.autoObserverClient.decide = { _, _, _ in nil }
    }

    await store.send(.autoObserverTriggered(id: sessionID)) {
      $0.autoObserverInFlight.insert(sessionID)
    }
    await store.receive(._autoObserverDecided(id: sessionID, response: nil)) {
      $0.autoObserverInFlight.remove(sessionID)
    }
    // No .sendText should be triggered when decision is nil — the test store
    // would fail exhaustiveness if send was called unexpectedly.
  }

  @Test(.dependencies) func autoObserverGuardsAgainstReentrance() async {
    let sessionID = UUID()
    var session = Self.sampleSession(id: sessionID)
    session.autoObserver = true
    var state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }
    state.autoObserverInFlight.insert(sessionID)

    let store = TestStore(initialState: state) {
      BoardFeature()
    }

    // Already in-flight → second trigger is a no-op.
    await store.send(.autoObserverTriggered(id: sessionID))
  }

  // MARK: - Rerun

  @Test(.dependencies) func convertSessionToWorktreeCreatesWorktreeAndSendsCD() async throws {
    // Confirming the "convert to worktree" popover on the repo-root pill
    // should create a worktree via gitClient and type `cd '<path>'` into
    // the session's focused surface. No surface/process churn — the tab
    // stays alive under its original `worktreeID` state key so hooks and
    // running agents are unaffected. The session's `currentWorkspacePath`
    // flips to the new worktree so the header badge, PR lookup, and
    // subsequent ⌘N all reflect the new workspace immediately.
    let original = Self.sampleSession(repositoryID: "/tmp/repo")
    let repo = Repository(
      id: "/tmp/repo",
      rootURL: URL(fileURLWithPath: "/tmp/repo"),
      name: "Repo",
      worktrees: []
    )
    let sentTexts = LockIsolated<[String]>([])
    let createdBranches = LockIsolated<[String]>([])
    var state = BoardFeature.State()
    state.$sessions.withLock { $0 = [original] }
    state.focusedSessionID = original.id

    let store = TestStore(initialState: state) {
      BoardFeature()
    } withDependencies: {
      $0.gitClient.createWorktree = { name, repoRoot, _, _, _, _ in
        createdBranches.withValue { $0.append(name) }
        return Worktree(
          id: "\(repoRoot.path)/worktrees/\(name)",
          name: name,
          detail: "",
          workingDirectory: URL(fileURLWithPath: "\(repoRoot.path)/worktrees/\(name)"),
          repositoryRootURL: repoRoot,
          createdAt: Date(),
          branch: name
        )
      }
      $0.terminalClient.send = { command in
        if case .sendText(_, _, let text) = command {
          sentTexts.withValue { $0.append(text) }
        }
      }
    }
    store.exhaustivity = .off

    await store.send(
      .convertSessionToWorktree(
        id: original.id,
        branchName: "feature/new-flow",
        repositories: [repo]
      )
    )
    await store.finish()

    #expect(createdBranches.value == ["feature/new-flow"])
    #expect(sentTexts.value == ["cd '/tmp/repo/worktrees/feature/new-flow'"])
    // Session is still in the list with the same focus, and the
    // immutable `worktreeID` state key is preserved so existing
    // terminal state lookups continue to resolve. Only the mutable
    // `currentWorkspacePath` field flips to the new worktree path.
    let updated = try #require(store.state.sessions.first(where: { $0.id == original.id }))
    #expect(updated.worktreeID == original.worktreeID)
    #expect(updated.currentWorkspacePath == "/tmp/repo/worktrees/feature/new-flow")
    #expect(store.state.focusedSessionID == original.id)
    #expect(store.state.newTerminalSheet == nil)
  }

  @Test(.dependencies) func openNewTerminalSheetFromSessionDoesNotReuseWorktree() async {
    // New-terminal is always a fresh dialog: even when launched from a
    // session that has been converted from repo root to a worktree, it
    // keeps only the repository preference and starts in the sheet's
    // default scope — a blank worktree — with an empty workspace field.
    let session = AgentSession(
      repositoryID: "/tmp/repo",
      worktreeID: "/tmp/repo", // started at repo root
      currentWorkspacePath: "/tmp/repo/worktrees/feature-x", // converted
      agent: .codex,
      initialPrompt: "Fix tests",
      planMode: true
    )
    let worktree = Worktree(
      id: "/tmp/repo/worktrees/feature-x",
      name: "feature-x",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/worktrees/feature-x"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo"),
      createdAt: Date(),
      branch: "feature-x"
    )
    let repo = Repository(
      id: "/tmp/repo",
      rootURL: URL(fileURLWithPath: "/tmp/repo"),
      name: "Repo",
      worktrees: [worktree]
    )
    var state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }
    state.focusedSessionID = session.id

    let store = TestStore(initialState: state) {
      BoardFeature()
    }
    store.exhaustivity = .off

    await store.send(
      .openNewTerminalSheetFromSession(id: session.id, repositories: [repo])
    )

    let sheet = store.state.newTerminalSheet
    #expect(sheet?.selectedRepositoryID == "/tmp/repo")
    #expect(sheet?.selectedWorkspace == .newBranch(name: ""))
    #expect(sheet?.workspaceQuery == "")
    #expect(sheet?.prompt == "")
    #expect(sheet?.agent == .claude)
    #expect(sheet?.planMode == false)
  }

  @Test(.dependencies) func repositoriesUpdatedRefreshesOpenNewTerminalSheet() async {
    // Regression: opening the New Terminal sheet during the async repo
    // load window used to freeze the picker on a stale snapshot. The
    // forwarded `_repositoriesUpdated` action must live-patch the open
    // sheet so the user doesn't have to close and reopen.
    let initialRepo = Repository(
      id: "/tmp/alpha",
      rootURL: URL(fileURLWithPath: "/tmp/alpha"),
      name: "alpha",
      worktrees: []
    )
    let addedRepo = Repository(
      id: "/tmp/beta",
      rootURL: URL(fileURLWithPath: "/tmp/beta"),
      name: "beta",
      worktrees: []
    )

    let store = TestStore(initialState: BoardFeature.State()) {
      BoardFeature()
    }
    store.exhaustivity = .off

    await store.send(.openNewTerminalSheet(repositories: [initialRepo]))
    #expect(store.state.newTerminalSheet?.availableRepositories.count == 1)
    #expect(store.state.newTerminalSheet?.selectedRepositoryID == initialRepo.id)

    await store.send(._repositoriesUpdated(repositories: [initialRepo, addedRepo]))
    #expect(store.state.newTerminalSheet?.availableRepositories.count == 2)
    // Selection sticks because the previous repo is still in the list.
    #expect(store.state.newTerminalSheet?.selectedRepositoryID == initialRepo.id)

    // Removing the currently selected repo must heal the selection to a
    // still-valid one rather than leaving a dangling id.
    await store.send(._repositoriesUpdated(repositories: [addedRepo]))
    #expect(store.state.newTerminalSheet?.availableRepositories.count == 1)
    #expect(store.state.newTerminalSheet?.selectedRepositoryID == addedRepo.id)
  }

  @Test(.dependencies) func repositoriesUpdatedIsNoOpWhenSheetClosed() async {
    let store = TestStore(initialState: BoardFeature.State()) {
      BoardFeature()
    }
    store.exhaustivity = .off

    let repo = Repository(
      id: "/tmp/alpha",
      rootURL: URL(fileURLWithPath: "/tmp/alpha"),
      name: "alpha",
      worktrees: []
    )
    await store.send(._repositoriesUpdated(repositories: [repo]))
    #expect(store.state.newTerminalSheet == nil)
  }

  @Test(.dependencies) func convertSessionToWorktreeIgnoresEmptyBranchName() async {
    let original = Self.sampleSession(repositoryID: "/tmp/repo")
    let repo = Repository(
      id: "/tmp/repo",
      rootURL: URL(fileURLWithPath: "/tmp/repo"),
      name: "Repo",
      worktrees: []
    )
    let state = BoardFeature.State()
    state.$sessions.withLock { $0 = [original] }

    let store = TestStore(initialState: state) {
      BoardFeature()
    }
    store.exhaustivity = .off

    // Whitespace-only branch name is a no-op — no effect runs, so no
    // gitClient / terminalClient overrides are required.
    await store.send(
      .convertSessionToWorktree(
        id: original.id,
        branchName: "   ",
        repositories: [repo]
      )
    )
    await store.finish()
  }

  @Test(.dependencies) func rerunDetachedSessionKeepsOriginalUntilCancel() async {
    // Clicking Rerun should NOT remove the original card from state —
    // otherwise a failed/cancelled sheet would lose the session and its
    // prompt. The original stays put until a new session is created
    // (`.created` delegate) or the sheet is cancelled.
    let session = Self.sampleSession()
    var state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }
    state.focusedSessionID = session.id

    let store = TestStore(initialState: state) {
      BoardFeature()
    }
    store.exhaustivity = .off

    await store.send(.rerunDetachedSession(id: session.id, repositories: [])) {
      $0.focusedSessionID = nil
      $0.pendingRerunSessionID = session.id
      // Sessions list is intentionally untouched.
    }
    #expect(store.state.sessions.contains(where: { $0.id == session.id }))

    await store.send(.newTerminalSheet(.presented(.delegate(.cancel)))) {
      $0.newTerminalSheet = nil
      $0.pendingRerunSessionID = nil
    }
    // Original session survives a cancelled rerun.
    #expect(store.state.sessions.contains(where: { $0.id == session.id }))
  }

  @Test(.dependencies) func rerunDetachedSessionDropsOriginalOnCreate() async {
    let original = Self.sampleSession(displayName: "Original")
    let state = BoardFeature.State()
    state.$sessions.withLock { $0 = [original] }

    let store = TestStore(initialState: state) {
      BoardFeature()
    } withDependencies: {
      // createSession kicks off background inference; stub it out.
      struct NoInference: Error {}
      $0.backgroundInferenceClient.infer = { _, _ in throw NoInference() }
    }
    store.exhaustivity = .off

    await store.send(.rerunDetachedSession(id: original.id, repositories: [])) {
      $0.pendingRerunSessionID = original.id
    }
    let replacement = Self.sampleSession(displayName: "Replacement")
    await store.send(.newTerminalSheet(.presented(.delegate(.created(replacement)))))
    await store.receive(.createSession(replacement))
    // Original is gone, replacement is in.
    #expect(!store.state.sessions.contains(where: { $0.id == original.id }))
    #expect(store.state.sessions.contains(where: { $0.id == replacement.id }))
    #expect(store.state.pendingRerunSessionID == nil)
  }

  @Test(.dependencies) func restoreShellSessionLayoutSendsTerminalRestoreCommand() async throws {
    let sessionID = UUID()
    let now = Date(timeIntervalSince1970: 1_750_000_123)
    let session = AgentSession(
      id: sessionID,
      repositoryID: "/tmp/repo",
      worktreeID: "/tmp/repo",
      currentWorkspacePath: "/tmp/repo/packages/api",
      agent: nil,
      initialPrompt: "",
      lastKnownBusy: true,
      parked: true
    )
    let repo = Repository(
      id: "/tmp/repo",
      rootURL: URL(fileURLWithPath: "/tmp/repo"),
      name: "Repo",
      worktrees: []
    )
    let sentCommands = LockIsolated<[TerminalClient.Command]>([])
    let state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }

    let store = TestStore(initialState: state) {
      BoardFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.terminalClient.send = { command in
        sentCommands.withValue { $0.append(command) }
      }
    }
    store.exhaustivity = .off

    await store.send(.restoreShellSessionLayout(id: sessionID, repositories: [repo])) {
      $0.$sessions.withLock { sessions in
        sessions[0].parked = false
        sessions[0].updatePrimaryTerminal {
          $0.lastKnownBusy = false
          $0.lastBusyTransitionAt = nil
          $0.lastActivityAt = now
        }
      }
      $0.reinitializingSessionIDs = [sessionID]
      $0.focusedSessionID = sessionID
    }
    await store.finish()

    let command = try #require(sentCommands.value.first)
    guard case .restoreShellLayout(let worktree, let tabID) = command else {
      Issue.record("Expected restoreShellLayout command, got \(command)")
      return
    }
    #expect(tabID.rawValue == sessionID)
    #expect(worktree.id == "/tmp/repo")
    #expect(worktree.workingDirectory.path(percentEncoded: false) == "/tmp/repo/packages/api")
  }

  @Test(.dependencies) func resumeDetachedSessionMarksReinitializingUntilTabExists() async throws {
    let sessionID = UUID()
    var session = Self.sampleSession(id: sessionID)
    session.updatePrimaryTerminal {
      $0.agentNativeSessionID = "native-session-123"
      $0.lastKnownBusy = true
    }
    session.parked = true
    let repo = Repository(
      id: session.repositoryID,
      rootURL: URL(fileURLWithPath: session.repositoryID),
      name: "Repo",
      worktrees: []
    )
    let sentCommands = LockIsolated<[TerminalClient.Command]>([])
    let state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }

    let store = TestStore(initialState: state) {
      BoardFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sentCommands.withValue { $0.append(command) }
      }
    }
    store.exhaustivity = .off

    await store.send(.resumeDetachedSession(id: sessionID, repositories: [repo]))

    #expect(store.state.reinitializingSessionIDs == [sessionID])
    #expect(store.state.sessions.first?.parked == false)
    #expect(store.state.sessions.first?.lastKnownBusy == false)
    #expect(store.state.focusedSessionID == sessionID)

    let command = try #require(sentCommands.value.first)
    guard case .createTabWithInput(let worktree, let input, let runSetupScriptIfNew, let id) = command else {
      Issue.record("Expected createTabWithInput command, got \(command)")
      return
    }
    #expect(worktree.id == session.worktreeID)
    #expect(input.contains("native-session-123"))
    #expect(runSetupScriptIfNew == false)
    #expect(id == sessionID)

    await store.send(.sessionTabPresenceObserved(id: sessionID, exists: true)) {
      $0.reinitializingSessionIDs = []
    }
    await store.finish()
  }

  @Test(.dependencies) func resumePickerMarksReinitializingUntilTabExists() async throws {
    let sessionID = UUID()
    var session = Self.sampleSession(id: sessionID)
    session.updatePrimaryTerminal { $0.agentNativeSessionID = nil }
    let repo = Repository(
      id: session.repositoryID,
      rootURL: URL(fileURLWithPath: session.repositoryID),
      name: "Repo",
      worktrees: []
    )
    let sentCommands = LockIsolated<[TerminalClient.Command]>([])
    let state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }

    let store = TestStore(initialState: state) {
      BoardFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sentCommands.withValue { $0.append(command) }
      }
    }
    store.exhaustivity = .off

    await store.send(.resumeDetachedSessionWithPicker(id: sessionID, repositories: [repo]))

    #expect(store.state.reinitializingSessionIDs == [sessionID])
    #expect(store.state.focusedSessionID == sessionID)
    let command = try #require(sentCommands.value.first)
    guard case .createTabWithInput(_, let input, let runSetupScriptIfNew, let id) = command else {
      Issue.record("Expected createTabWithInput picker command, got \(command)")
      return
    }
    #expect(input.contains("--resume"))
    #expect(runSetupScriptIfNew == false)
    #expect(id == sessionID)

    await store.send(.sessionTabPresenceObserved(id: sessionID, exists: true)) {
      $0.reinitializingSessionIDs = []
    }
    await store.finish()
  }

  @Test(.dependencies) func reconnectRemoteSessionMarksReinitializingUntilTabExists() async throws {
    let sessionID = UUID()
    let hostID = UUID()
    let workspaceID = UUID()
    var session = Self.sampleSession(
      id: sessionID,
      repositoryID: "/tmp/repo",
      worktreeID: "remote://prod/app"
    )
    session.remoteWorkspaceID = workspaceID
    session.remoteHostID = hostID
    session.tmuxSessionName = "supacool-\(sessionID.uuidString.lowercased())"
    session.remoteConnectionLost = true
    let host = RemoteHost(
      id: hostID,
      sshAlias: "prod",
      connection: .init(user: "deploy", hostname: "prod.example.com"),
      deferToSSHConfig: false
    )
    let workspace = RemoteWorkspace(
      id: workspaceID,
      hostID: hostID,
      remoteWorkingDirectory: "/srv/app"
    )
    let sentCommands = LockIsolated<[TerminalClient.Command]>([])
    let state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }
    state.$remoteHosts.withLock { $0 = [host] }
    state.$remoteWorkspaces.withLock { $0 = [workspace] }

    let store = TestStore(initialState: state) {
      BoardFeature()
    } withDependencies: {
      $0.terminalClient.hookSocketPath = { "/tmp/supacool.sock" }
      $0.terminalClient.send = { command in
        sentCommands.withValue { $0.append(command) }
      }
    }
    store.exhaustivity = .off

    await store.send(.reconnectRemoteSession(id: sessionID))

    #expect(store.state.reinitializingSessionIDs == [sessionID])
    #expect(store.state.sessions.first?.remoteConnectionLost == false)

    let commands = sentCommands.value
    #expect(commands.count == 2)
    guard case .destroyTab(let destroyedWorktree, let destroyedTabID) = try #require(commands.first) else {
      Issue.record("Expected destroyTab command, got \(String(describing: commands.first))")
      return
    }
    #expect(destroyedWorktree.id == session.worktreeID)
    #expect(destroyedTabID.rawValue == sessionID)

    guard
      case .createRemoteTab(let worktree, let command, let id, let surfaceID) = try #require(commands.last)
    else {
      Issue.record("Expected createRemoteTab command, got \(String(describing: commands.last))")
      return
    }
    #expect(worktree.id == session.worktreeID)
    #expect(!command.isEmpty)
    #expect(id == sessionID)
    #expect(surfaceID == sessionID)

    await store.send(.sessionTabPresenceObserved(id: sessionID, exists: true)) {
      $0.reinitializingSessionIDs = []
    }
    await store.finish()
  }

  @Test(.dependencies) func restoreShellSessionLayoutIgnoresAgentSessions() async {
    let session = Self.sampleSession()
    let state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }
    let sentCommands = LockIsolated<[TerminalClient.Command]>([])

    let store = TestStore(initialState: state) {
      BoardFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sentCommands.withValue { $0.append(command) }
      }
    }
    store.exhaustivity = .off

    await store.send(.restoreShellSessionLayout(id: session.id, repositories: []))
    await store.receive(.resumeFailed(id: session.id, message: "Only local shell sessions can restore a shell layout."))
    await store.finish()

    #expect(sentCommands.value.isEmpty)
  }

  // MARK: - Worktree prune

  @Test(.dependencies) func pruneWorktreesHappyPath() async {
    let store = TestStore(initialState: BoardFeature.State()) {
      BoardFeature()
    } withDependencies: {
      $0.supacoolWorktreePrune.prune = { _ in
        SupacoolPruneResult(prunedRefs: ["foo", "bar"], rawOutput: "")
      }
    }
    store.exhaustivity = .off

    await store.send(
      .pruneWorktreesRequested(repositoryID: "/tmp/repo", repositoryName: "repo")
    )
    await store.receive(\._pruneWorktreesResult)

    guard let alert = store.state.pruneAlert,
      case .success(let prunedCount, let orphanSessionIDs) = alert.outcome
    else {
      Issue.record("Expected success outcome, got \(String(describing: store.state.pruneAlert))")
      return
    }
    #expect(prunedCount == 2)
    #expect(orphanSessionIDs.isEmpty)
    #expect(alert.repositoryName == "repo")
  }

  @Test(.dependencies) func pruneWorktreesFindsOrphanSessions() async {
    // A session whose worktreeID path doesn't exist → orphan.
    let ghost = Self.sampleSession(
      repositoryID: "/tmp/repo",
      worktreeID: "/tmp/does-not-exist-\(UUID().uuidString)"
    )
    // A session running at repo root (worktreeID == repositoryID) must
    // NOT be flagged as an orphan even if /tmp/repo itself doesn't
    // exist, per the helper's contract.
    let rootSession = Self.sampleSession(
      repositoryID: "/tmp/repo",
      worktreeID: "/tmp/repo"
    )
    let state = BoardFeature.State()
    state.$sessions.withLock { $0 = [ghost, rootSession] }

    let store = TestStore(initialState: state) {
      BoardFeature()
    } withDependencies: {
      $0.supacoolWorktreePrune.prune = { _ in
        SupacoolPruneResult(prunedRefs: ["gone"], rawOutput: "")
      }
    }
    store.exhaustivity = .off

    await store.send(
      .pruneWorktreesRequested(repositoryID: "/tmp/repo", repositoryName: "repo")
    )
    await store.receive(\._pruneWorktreesResult)

    guard let alert = store.state.pruneAlert,
      case .success(let prunedCount, let orphanSessionIDs) = alert.outcome
    else {
      Issue.record("Expected success outcome")
      return
    }
    #expect(prunedCount == 1)
    #expect(orphanSessionIDs == [ghost.id])
  }

  @Test(.dependencies) func pruneWorktreesConfirmOrphanRemovalDispatchesRemoveSession() async {
    let orphanA = Self.sampleSession()
    let orphanB = Self.sampleSession()
    let state = BoardFeature.State()
    state.$sessions.withLock { $0 = [orphanA, orphanB] }

    let store = TestStore(initialState: state) {
      BoardFeature()
    } withDependencies: {
      // .removeSession now reads `\.date` to stamp the trash entry.
      $0.date = .constant(Date(timeIntervalSince1970: 1_750_000_000))
    }
    store.exhaustivity = .off

    await store.send(.confirmPruneOrphans(sessionIDs: [orphanA.id, orphanB.id]))

    // Both removals should flow through the existing .removeSession path.
    await store.receive(.removeSession(id: orphanA.id))
    await store.receive(.removeSession(id: orphanB.id))
    #expect(store.state.sessions.isEmpty)
  }

  @Test(.dependencies) func pruneWorktreesNothingToClean() async {
    let store = TestStore(initialState: BoardFeature.State()) {
      BoardFeature()
    } withDependencies: {
      $0.supacoolWorktreePrune.prune = { _ in
        SupacoolPruneResult(prunedRefs: [], rawOutput: "")
      }
    }
    store.exhaustivity = .off

    await store.send(
      .pruneWorktreesRequested(repositoryID: "/tmp/repo", repositoryName: "repo")
    )
    await store.receive(\._pruneWorktreesResult)

    guard let alert = store.state.pruneAlert,
      case .success(let prunedCount, let orphanSessionIDs) = alert.outcome
    else {
      Issue.record("Expected success outcome")
      return
    }
    #expect(prunedCount == 0)
    #expect(orphanSessionIDs.isEmpty)
  }

  @Test(.dependencies) func pruneWorktreesFailureShowsError() async {
    struct PruneExploded: LocalizedError {
      var errorDescription: String? { "git exploded" }
    }
    let store = TestStore(initialState: BoardFeature.State()) {
      BoardFeature()
    } withDependencies: {
      $0.supacoolWorktreePrune.prune = { _ in throw PruneExploded() }
    }
    store.exhaustivity = .off

    await store.send(
      .pruneWorktreesRequested(repositoryID: "/tmp/repo", repositoryName: "repo")
    )
    await store.receive(\._pruneWorktreesResult)

    guard let alert = store.state.pruneAlert,
      case .failure(let message) = alert.outcome
    else {
      Issue.record("Expected failure outcome")
      return
    }
    #expect(message == "git exploded")
  }

  @Test func parsePrunedRefsExtractsRemovedNames() {
    let sample = """
      Removing worktrees/foo: gitdir file points to non-existent location
      Removing worktrees/bar-baz: some reason
      unrelated chatter line
      """
    #expect(parsePrunedRefs(from: sample) == ["foo", "bar-baz"])
  }

  @Test func parsePrunedRefsReturnsEmptyOnCleanOutput() {
    #expect(parsePrunedRefs(from: "") == [])
    #expect(parsePrunedRefs(from: "nothing pruned") == [])
  }

  // MARK: - Tray cards

  @Test(.dependencies) func trayCardPushedAppendsCard() async {
    let store = TestStore(initialState: BoardFeature.State()) {
      BoardFeature()
    }
    let card = TrayCard(kind: .staleHooks(slots: [.claudeProgress]))
    await store.send(.trayCardPushed(card)) {
      $0.trayCards = [card]
    }
  }

  @Test(.dependencies) func trayCardPushedDedupesByKind() async {
    // A second push with an identical kind — even if the id differs —
    // should be dropped so repeated launches don't stack duplicates.
    var state = BoardFeature.State()
    let existing = TrayCard(kind: .staleHooks(slots: [.claudeProgress]))
    state.trayCards = [existing]
    let store = TestStore(initialState: state) {
      BoardFeature()
    }
    let duplicate = TrayCard(kind: .staleHooks(slots: [.claudeProgress]))
    await store.send(.trayCardPushed(duplicate))
    // No state change expected; exhaustive store would fail if one occurred.
  }

  @Test(.dependencies) func trayCardDismissedRemovesCard() async {
    var state = BoardFeature.State()
    let card = TrayCard(kind: .staleHooks(slots: [.claudeProgress]))
    state.trayCards = [card]
    let store = TestStore(initialState: state) {
      BoardFeature()
    }
    await store.send(.trayCardDismissed(id: card.id)) {
      $0.trayCards = []
    }
  }

  @Test(.dependencies) func trayCardPrimaryTappedStaleHooksRoutesToSettings() async {
    var state = BoardFeature.State()
    let card = TrayCard(kind: .staleHooks(slots: [.codexNotifications]))
    state.trayCards = [card]
    let store = TestStore(initialState: state) {
      BoardFeature()
    }
    await store.send(.trayCardPrimaryTapped(id: card.id)) {
      $0.trayCards = []
    }
    await store.receive(\.delegate.openSettingsRequested)
  }

  @Test(.dependencies) func updateSessionBusyTrueClearsSessionCreatingCard() async {
    // The "Starting session" card auto-dismisses on the session's first
    // busy=true transition — that's the signal the PTY is live and the
    // agent is actually running.
    let session = Self.sampleSession(displayName: "Starting soon")
    var state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }
    state.trayCards = [Self.sessionCreatingCard(for: session)]
    let store = TestStore(initialState: state) {
      BoardFeature()
    }
    // Timestamps are injected via non-deterministic `Date()` in the
    // reducer — exhaustive equality would flake, so we check tray
    // clearance separately.
    store.exhaustivity = .off

    await store.send(.updateSessionBusyState(id: session.id, busy: true))
    #expect(store.state.trayCards.isEmpty)
  }

  @Test(.dependencies) func updateSessionBusyFalseKeepsSessionCreatingCard() async {
    // A busy=false transition alone must NOT clear the progress
    // indicator. Status observation is the separate fallback path.
    let session = Self.sampleSession(displayName: "Starting soon")
    var state = BoardFeature.State()
    state.$sessions.withLock {
      $0 = [session]
      $0[0].updatePrimaryTerminal { $0.lastKnownBusy = true }
    }
    let card = Self.sessionCreatingCard(for: session)
    state.trayCards = [card]
    let store = TestStore(initialState: state) {
      BoardFeature()
    }
    store.exhaustivity = .off

    await store.send(.updateSessionBusyState(id: session.id, busy: false))
    #expect(store.state.trayCards == [card])
  }

  @Test(.dependencies) func sessionStatusObservedFreshClearsSessionCreatingCard() async {
    let session = Self.sampleSession(displayName: "Starting soon")
    var state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }
    state.trayCards = [Self.sessionCreatingCard(for: session)]
    let store = TestStore(initialState: state) {
      BoardFeature()
    }

    await store.send(.sessionStatusObserved(id: session.id, status: .fresh)) {
      $0.trayCards = []
    }
  }

  @Test(.dependencies) func sessionStatusObservedDetachedKeepsSessionCreatingCard() async {
    let session = Self.sampleSession(displayName: "Starting soon")
    let card = Self.sessionCreatingCard(for: session)
    var state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }
    state.trayCards = [card]
    let store = TestStore(initialState: state) {
      BoardFeature()
    }

    await store.send(.sessionStatusObserved(id: session.id, status: .detached))
    #expect(store.state.trayCards == [card])
  }

  @Test(.dependencies) func trayCardPrimaryTappedSessionCreatingFocusesSession() async {
    let session = Self.sampleSession(displayName: "Deploy")
    var state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }
    let card = Self.sessionCreatingCard(for: session)
    state.trayCards = [card]
    let store = TestStore(initialState: state) {
      BoardFeature()
    }

    await store.send(.trayCardPrimaryTapped(id: card.id)) {
      $0.trayCards = []
    }
    await store.receive(.focusSession(id: session.id)) {
      $0.focusedSessionID = session.id
    }
  }

  @Test(.dependencies) func removeSessionClearsLingeringSessionCreatingCard() async {
    // If the user trashes a card before the first busy transition fires
    // (e.g. a fast-fail spawn), the creating-card should go too.
    let session = Self.sampleSession()
    var state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }
    state.$trashedSessions.withLock { $0 = [] }
    state.trayCards = [Self.sessionCreatingCard(for: session)]
    let store = TestStore(initialState: state) {
      BoardFeature()
    } withDependencies: {
      // .removeSession reads `\.date` to stamp the trash entry.
      $0.date = .constant(Date(timeIntervalSince1970: 1_750_000_000))
    }
    // Reducer writes to $trashedSessions; this test only cares about
    // tray-card cleanup, so the rest of the state is non-exhaustive.
    store.exhaustivity = .off

    await store.send(.removeSession(id: session.id)) {
      $0.trayCards = []
    }
    await store.receive(\.delegate.sessionRemoved)
  }

  @Test(.dependencies) func trayCardSecondaryTappedStaleHooksRequestsReinstall() async {
    // Optimistic: the card clears immediately on Reinstall tap, the
    // delegate carries the slots forward for AppFeature to fan out.
    let card = TrayCard(
      kind: .staleHooks(slots: [.claudeProgress, .codexNotifications])
    )
    var state = BoardFeature.State()
    state.trayCards = [card]
    let store = TestStore(initialState: state) {
      BoardFeature()
    }

    await store.send(.trayCardSecondaryTapped(id: card.id)) {
      $0.trayCards = []
    }
    await store.receive(\.delegate.reinstallHooksRequested)
  }

  @Test(.dependencies) func trayNoteHookInstalledNarrowsStaleCard() async {
    // A per-slot success narrows a multi-slot stale card rather than
    // removing it outright — the remaining drift still needs fixing.
    let card = TrayCard(
      kind: .staleHooks(slots: [.claudeProgress, .codexNotifications])
    )
    var state = BoardFeature.State()
    state.trayCards = [card]
    let store = TestStore(initialState: state) {
      BoardFeature()
    }

    await store.send(.trayNoteHookInstalled(slot: .claudeProgress)) {
      $0.trayCards[id: card.id]?.kind = .staleHooks(slots: [.codexNotifications])
    }
  }

  @Test(.dependencies) func trayNoteHookInstalledRemovesCardWhenEmpty() async {
    let card = TrayCard(kind: .staleHooks(slots: [.codexProgress]))
    var state = BoardFeature.State()
    state.trayCards = [card]
    let store = TestStore(initialState: state) {
      BoardFeature()
    }

    await store.send(.trayNoteHookInstalled(slot: .codexProgress)) {
      $0.trayCards = []
    }
  }

  @Test(.dependencies) func trayNoteHookInstalledClearsMatchingFailureCard() async {
    // A retry success should dismiss a stale failure card for the same
    // slot — the user shouldn't have to × a resolved error.
    let failureCard = TrayCard(
      kind: .hookInstallFailed(slot: .claudeNotifications, message: "boom")
    )
    var state = BoardFeature.State()
    state.trayCards = [failureCard]
    let store = TestStore(initialState: state) {
      BoardFeature()
    }

    await store.send(.trayNoteHookInstalled(slot: .claudeNotifications)) {
      $0.trayCards = []
    }
  }

  @Test(.dependencies) func trayCardPrimaryTappedHookInstallFailedOpensSettings() async {
    let card = TrayCard(
      kind: .hookInstallFailed(slot: .claudeProgress, message: "permission denied")
    )
    var state = BoardFeature.State()
    state.trayCards = [card]
    let store = TestStore(initialState: state) {
      BoardFeature()
    }

    await store.send(.trayCardPrimaryTapped(id: card.id)) {
      $0.trayCards = []
    }
    await store.receive(\.delegate.openSettingsRequested)
  }

  @Test(.dependencies) func trayCardPrimaryTappedWorktreeDeleteFailedJustDismisses() async {
    let card = TrayCard(
      kind: .worktreeDeleteFailed(path: "/tmp/repo/feat-x", message: "permission denied")
    )
    var state = BoardFeature.State()
    state.trayCards = [card]
    let store = TestStore(initialState: state) {
      BoardFeature()
    }

    await store.send(.trayCardPrimaryTapped(id: card.id)) {
      $0.trayCards = []
    }
  }

  /// Tapping a `.sessionSpawnFailed` card that carries a draft snapshot
  /// reopens the New Terminal sheet with the user's submitted values
  /// pre-filled. This is the recovery affordance for a failed
  /// submission — same path the draft pill uses, just triggered from
  /// the failure card instead.
  @Test(.dependencies) func trayCardPrimaryTappedSessionSpawnFailedWithDraftReopensSheet() async {
    let repo = Repository(
      id: "/tmp/repo",
      rootURL: URL(fileURLWithPath: "/tmp/repo"),
      name: "test-repo",
      worktrees: []
    )
    let snapshot = Draft(
      id: UUID(),
      repositoryID: "/tmp/repo",
      prompt: "Retry me",
      agent: .claude,
      workspaceQuery: "feat-retry",
      planMode: false
    )
    let card = TrayCard(
      kind: .sessionSpawnFailed(
        displayName: "Retry me",
        message: "Git command failed",
        draftSnapshot: snapshot
      )
    )
    var state = BoardFeature.State()
    state.trayCards = [card]
    let store = TestStore(initialState: state) {
      BoardFeature()
    }
    // Sheet state carries non-trivial internal computed fields (branch
    // lists, PR lookup, etc.) so we can't assert the entire shape
    // exhaustively — just confirm the sheet appears with the snapshot
    // values restored.
    store.exhaustivity = .off

    await store.send(.trayCardPrimaryTapped(id: card.id, repositories: [repo]))
    #expect(store.state.trayCards.isEmpty)
    #expect(store.state.newTerminalSheet?.prompt == "Retry me")
    #expect(store.state.newTerminalSheet?.agent == .claude)
    #expect(store.state.newTerminalSheet?.workspaceQuery == "feat-retry")
    #expect(store.state.newTerminalSheet?.selectedRepositoryID == "/tmp/repo")
  }

  /// Copy button puts "title\nmessage" on the pasteboard for any error
  /// card. Card stays visible — copying is non-destructive so the user
  /// can still Debug or × after pasting.
  @Test(.dependencies) func trayCardCopyTappedPutsTitleAndMessageOnPasteboard() async {
    let card = TrayCard(
      kind: .sessionSpawnFailed(
        displayName: "Retry me",
        message: "Git command failed: permission denied",
        draftSnapshot: nil
      )
    )
    var state = BoardFeature.State()
    state.trayCards = [card]
    let store = TestStore(initialState: state) {
      BoardFeature()
    }
    let pb = NSPasteboard.general
    pb.clearContents()

    await store.send(.trayCardCopyTapped(id: card.id))
    #expect(store.state.trayCards.count == 1)  // card stays
    #expect(pb.string(forType: .string) == "Couldn't start Retry me\nGit command failed: permission denied")
  }

  /// Copy is a no-op on non-error cards (no `errorContent`). Nothing
  /// on the pasteboard, card stays put.
  @Test(.dependencies) func trayCardCopyTappedStaleHooksIsNoOp() async {
    let card = TrayCard(kind: .staleHooks(slots: [.claudeProgress]))
    var state = BoardFeature.State()
    state.trayCards = [card]
    let store = TestStore(initialState: state) {
      BoardFeature()
    }
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString("sentinel", forType: .string)

    await store.send(.trayCardCopyTapped(id: card.id))
    #expect(store.state.trayCards.count == 1)
    #expect(pb.string(forType: .string) == "sentinel")
  }

  /// Debug button opens the debug sheet with a `.spawnFailure` source
  /// seeded from the card's title + message, and removes the card.
  /// Skipped if no registered repo holds `supacool.xcodeproj` — but
  /// we can't easily fabricate one in tests, so this test asserts the
  /// no-supacool-repo branch is a no-op and a second test would need a
  /// real filesystem fixture for the happy path. Here we cover the
  /// guard path.
  @Test(.dependencies) func trayCardDebugTappedWithoutSupacoolRepoIsNoOp() async {
    let card = TrayCard(
      kind: .hookInstallFailed(slot: .claudeProgress, message: "boom")
    )
    var state = BoardFeature.State()
    state.trayCards = [card]
    let store = TestStore(initialState: state) {
      BoardFeature()
    }
    let unrelatedRepo = Repository(
      id: "/tmp/not-supacool",
      rootURL: URL(fileURLWithPath: "/tmp/not-supacool"),
      name: "not-supacool",
      worktrees: []
    )

    await store.send(.trayCardDebugTapped(id: card.id, repositories: [unrelatedRepo]))
    #expect(store.state.trayCards.count == 1)
    #expect(store.state.debugSheet == nil)
  }

  /// A `.sessionSpawnFailed` card without a snapshot (e.g. a conflict-
  /// recovery retry that failed past the sheet) should just dismiss
  /// on tap rather than opening an empty New Terminal sheet.
  @Test(.dependencies) func trayCardPrimaryTappedSessionSpawnFailedNoSnapshotDismisses() async {
    let card = TrayCard(
      kind: .sessionSpawnFailed(
        displayName: "Past-the-sheet failure",
        message: "boom",
        draftSnapshot: nil
      )
    )
    var state = BoardFeature.State()
    state.trayCards = [card]
    let store = TestStore(initialState: state) {
      BoardFeature()
    }

    await store.send(.trayCardPrimaryTapped(id: card.id)) {
      $0.trayCards = []
    }
    #expect(store.state.newTerminalSheet == nil)
  }

  // MARK: - Worktree-conflict alert

  @Test(.dependencies) func sessionSpawnConflictPresentsAlertAndKeepsPlaceholder() async {
    let sessionID = UUID()
    let displayName = "Continue work"
    let alertID = UUID(uuidString: "AAAAAAAA-1234-1234-1234-AAAAAAAAAAAA")!
    let placeholder = TrayCard(
      id: sessionID,
      kind: .sessionCreating(sessionID: sessionID, displayName: displayName)
    )
    let request = Self.sampleSpawnRequest(sessionID: sessionID)
    let existing = Self.sampleConflictingWorktree(branch: "feat/x")
    var state = BoardFeature.State()
    state.trayCards = [placeholder]
    let store = TestStore(initialState: state) {
      BoardFeature()
    } withDependencies: {
      $0.uuid = .constant(alertID)
    }

    await store.send(
      ._sessionSpawnConflict(
        sessionID: sessionID,
        placeholderDisplayName: displayName,
        request: request,
        branch: "feat/x",
        existing: existing
      )
    ) {
      $0.worktreeConflictAlert = BoardFeature.WorktreeConflictAlertState(
        id: alertID,
        sessionID: sessionID,
        placeholderDisplayName: displayName,
        request: request,
        branch: "feat/x",
        existingWorktree: existing
      )
    }
    // Placeholder stays — user gets a visual anchor while they pick.
    #expect(store.state.trayCards.contains(where: { $0.id == sessionID }))
  }

  @Test(.dependencies) func dismissWorktreeConflictAlertClearsAlertAndDropsPlaceholder() async {
    let sessionID = UUID()
    let displayName = "Continue work"
    let placeholder = TrayCard(
      id: sessionID,
      kind: .sessionCreating(sessionID: sessionID, displayName: displayName)
    )
    let request = Self.sampleSpawnRequest(sessionID: sessionID)
    let alert = BoardFeature.WorktreeConflictAlertState(
      sessionID: sessionID,
      placeholderDisplayName: displayName,
      request: request,
      branch: "feat/x",
      existingWorktree: Self.sampleConflictingWorktree(branch: "feat/x")
    )
    var state = BoardFeature.State()
    state.trayCards = [placeholder]
    state.worktreeConflictAlert = alert
    let store = TestStore(initialState: state) {
      BoardFeature()
    }

    await store.send(.dismissWorktreeConflictAlert) {
      $0.worktreeConflictAlert = nil
      $0.trayCards = []
    }
  }

  @Test(.dependencies)
  func dismissWorktreeConflictAlertWithNoAlertIsNoOp() async {
    let store = TestStore(initialState: BoardFeature.State()) {
      BoardFeature()
    }
    await store.send(.dismissWorktreeConflictAlert)
  }

  // MARK: - Helpers

  private struct LifecycleCall: Equatable, Sendable {
    let kind: ServerLifecycleScriptKind
    let script: String
    let context: ServerLifecycleScriptContext
  }

  private static func sessionCreatingCard(for session: AgentSession) -> TrayCard {
    TrayCard(
      id: session.id,
      kind: .sessionCreating(sessionID: session.id, displayName: session.displayName)
    )
  }

  private static func configureServerLifecycle(
    repositoryID: String,
    name: String = "Dev server",
    statusScript: String = "",
    startScript: String = "",
    stopScript: String = "",
    autoStopOnSessionRemove: Bool = true,
    autoStopOnPark: Bool = true,
    autoStartOnUnpark: Bool = false
  ) {
    @Shared(.repositorySettings(URL(fileURLWithPath: repositoryID))) var settings: RepositorySettings
    $settings.withLock {
      $0 = .default
      $0.serverLifecycle = ServerLifecycleSettings(
        name: name,
        statusScript: statusScript,
        startScript: startScript,
        stopScript: stopScript,
        autoStopOnSessionRemove: autoStopOnSessionRemove,
        autoStopOnPark: autoStopOnPark,
        autoStartOnUnpark: autoStartOnUnpark
      )
    }
  }

  private static func lifecycleContext(
    for session: AgentSession,
    event: String
  ) -> ServerLifecycleScriptContext {
    ServerLifecycleScriptContext(
      event: event,
      sessionID: session.id.uuidString.lowercased(),
      sessionName: session.displayName
    )
  }

  private static func sampleSession(
    id: UUID = UUID(),
    repositoryID: String = "/tmp/repo",
    worktreeID: String? = nil,
    displayName: String? = nil,
    removeBackingWorktreeOnDelete: Bool = false,
    isPriority: Bool = false
  ) -> AgentSession {
    AgentSession(
      id: id,
      repositoryID: repositoryID,
      worktreeID: worktreeID ?? repositoryID,
      agent: .claude,
      initialPrompt: "Fix the failing tests",
      displayName: displayName,
      removeBackingWorktreeOnDelete: removeBackingWorktreeOnDelete,
      isPriority: isPriority
    )
  }

  private static func sampleSpawnRequest(
    sessionID: UUID,
    branch: String = "feat/x"
  ) -> SessionSpawner.LocalRequest {
    SessionSpawner.LocalRequest(
      sessionID: sessionID,
      repository: Repository(
        id: "/tmp/repo",
        rootURL: URL(fileURLWithPath: "/tmp/repo"),
        name: "test-repo",
        worktrees: []
      ),
      selection: .existingBranch(name: branch),
      agent: .claude,
      prompt: "Continue work",
      planMode: false,
      bypassPermissions: true,
      fetchOriginBeforeCreation: false,
      rerunOwnedWorktreeID: nil,
      pullRequestLookup: .idle,
      suggestedDisplayName: nil,
      removeBackingWorktreeOnDelete: true
    )
  }

  private static func sampleConflictingWorktree(
    branch: String,
    repoRoot: URL = URL(fileURLWithPath: "/tmp/repo")
  ) -> Worktree {
    let url = URL(fileURLWithPath: "/tmp/conflict/elsewhere/\(branch)").standardizedFileURL
    return Worktree(
      id: url.path(percentEncoded: false),
      name: branch,
      detail: "",
      workingDirectory: url,
      repositoryRootURL: repoRoot,
      branch: branch
    )
  }
}
