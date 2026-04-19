import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import Supacool

@MainActor
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
      $0.backgroundInferenceClient.infer = { _ in throw NoInference() }
    }
    let session = Self.sampleSession()

    // createSession intentionally does NOT focus the new card — the user
    // stays on the board and sees it appear in "In Progress."
    await store.send(.createSession(session)) {
      $0.$sessions.withLock { $0 = [session] }
    }
  }

  @Test(.dependencies) func createSessionRefinesDisplayNameViaInference() async {
    let store = TestStore(initialState: BoardFeature.State()) {
      BoardFeature()
    } withDependencies: {
      $0.backgroundInferenceClient.infer = { _ in "Fix Failing Unit Tests" }
    }
    let session = Self.sampleSession()  // prompt: "Fix the failing tests" → derived "Fix the failing tests"
    let sessionID = session.id

    await store.send(.createSession(session)) {
      $0.$sessions.withLock { $0 = [session] }
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
      $0.backgroundInferenceClient.infer = { _ in "LLM Generated Name" }
    }
    // Pin a custom displayName up front (simulates the PR-URL flow
    // setting "PR #42: Fix the widget"). The inference result must NOT
    // clobber it.
    let session = Self.sampleSession(displayName: "PR #42: Fix the widget")
    await store.send(.createSession(session)) {
      $0.$sessions.withLock { $0 = [session] }
    }
    // No _autoDisplayNameSuggested is expected — the effect short-circuits
    // before calling infer because displayName != deriveDisplayName(prompt).
  }

  @Test(.dependencies) func renameSessionUpdatesDisplayName() async {
    let session = Self.sampleSession(displayName: "Old Name")
    var state = BoardFeature.State()
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
    var state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }

    let store = TestStore(initialState: state) {
      BoardFeature()
    }

    // Whitespace-only rename should be a no-op.
    await store.send(.renameSession(id: session.id, newName: "   "))
  }

  @Test(.dependencies) func removeSessionDropsItAndClearsFocusIfFocused() async {
    let session = Self.sampleSession()
    var state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }
    state.focusedSessionID = session.id

    let store = TestStore(initialState: state) {
      BoardFeature()
    }

    await store.send(.removeSession(id: session.id)) {
      $0.$sessions.withLock { $0 = [] }
      $0.focusedSessionID = nil
    }
    await store.receive(
      .delegate(
        .sessionRemoved(
          sessionID: session.id,
          repositoryID: session.repositoryID,
          worktreeID: session.worktreeID,
          deleteBackingWorktree: false
        )
      )
    )
  }

  @Test(.dependencies) func removeSessionDelegatesOwnedWorktreeDeletion() async {
    let session = Self.sampleSession(
      repositoryID: "/tmp/repo",
      worktreeID: "/tmp/repo/wt-1",
      removeBackingWorktreeOnDelete: true
    )
    var state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }

    let store = TestStore(initialState: state) {
      BoardFeature()
    }

    await store.send(.removeSession(id: session.id)) {
      $0.$sessions.withLock { $0 = [] }
    }
    await store.receive(
      .delegate(
        .sessionRemoved(
          sessionID: session.id,
          repositoryID: "/tmp/repo",
          worktreeID: "/tmp/repo/wt-1",
          deleteBackingWorktree: true
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
    var state = BoardFeature.State()
    state.$sessions.withLock { $0 = [removed, sibling] }

    let store = TestStore(initialState: state) {
      BoardFeature()
    }

    await store.send(.removeSession(id: removed.id)) {
      $0.$sessions.withLock { sessions in
        sessions = [sibling]
      }
    }
    await store.receive(
      .delegate(
        .sessionRemoved(
          sessionID: removed.id,
          repositoryID: "/tmp/repo",
          worktreeID: worktreeID,
          deleteBackingWorktree: false
        )
      )
    )
  }

  @Test(.dependencies) func markCompletedOnceSetsFlag() async {
    let session = Self.sampleSession()
    var state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }

    let store = TestStore(initialState: state) {
      BoardFeature()
    }
    store.exhaustivity = .off

    await store.send(.markSessionCompletedOnce(id: session.id)) {
      $0.$sessions.withLock { $0[0].hasCompletedAtLeastOnce = true }
    }

    // Second call is a no-op — flag is already set and lastActivityAt stays.
    await store.send(.markSessionCompletedOnce(id: session.id))
  }

  @Test(.dependencies) func updateSessionBusyStatePersistsTransitionTimestamp() async {
    let session = Self.sampleSession()
    var state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }

    let store = TestStore(initialState: state) {
      BoardFeature()
    }
    store.exhaustivity = .off

    await store.send(.updateSessionBusyState(id: session.id, busy: true)) {
      $0.$sessions.withLock { sessions in
        sessions[0].lastKnownBusy = true
        #expect(sessions[0].lastBusyTransitionAt != nil)
      }
    }

    await store.send(.updateSessionBusyState(id: session.id, busy: false)) {
      $0.$sessions.withLock { sessions in
        sessions[0].lastKnownBusy = false
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
    var state = BoardFeature.State()
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

  // MARK: - Visibility query

  @Test(.dependencies) func visibleSessionsFiltersByRepo() {
    let sessionA = Self.sampleSession(repositoryID: "/tmp/a")
    let sessionB = Self.sampleSession(repositoryID: "/tmp/b")
    var state = BoardFeature.State()
    state.$sessions.withLock { $0 = [sessionA, sessionB] }
    state.$filters.withLock { $0.selectedRepositoryIDs = ["/tmp/a"] }

    #expect(state.visibleSessions.map(\.id) == [sessionA.id])
    #expect(state.filters.includes(repositoryID: "/tmp/a"))
    #expect(!state.filters.includes(repositoryID: "/tmp/b"))
  }

  @Test(.dependencies) func visibleSessionsShowsAllWhenFilterEmpty() {
    let sessionA = Self.sampleSession(repositoryID: "/tmp/a")
    let sessionB = Self.sampleSession(repositoryID: "/tmp/b")
    var state = BoardFeature.State()
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
    var state = BoardFeature.State()
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
    var state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }

    let store = TestStore(initialState: state) {
      BoardFeature()
    } withDependencies: {
      $0.terminalClient.readScreenContents = { _, _ in "Continue? (y/n)" }
      $0.terminalClient.send = { _ in }
      $0.autoObserverClient.decide = { _, _ in "y" }
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
    var state = BoardFeature.State()
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
    var state = BoardFeature.State()
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
    var state = BoardFeature.State()
    state.$sessions.withLock { $0 = [modifiedSession] }

    let tabID = TerminalTabID(rawValue: sessionID)
    let store = TestStore(initialState: state) {
      BoardFeature()
    } withDependencies: {
      $0.terminalClient.readScreenContents = { _, _ in "Continue? (y/n)" }
      $0.terminalClient.send = { _ in }
      $0.autoObserverClient.decide = { _, _ in "y" }
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
    var state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }

    let store = TestStore(initialState: state) {
      BoardFeature()
    } withDependencies: {
      $0.terminalClient.readScreenContents = { _, _ in "Some ambiguous output" }
      $0.autoObserverClient.decide = { _, _ in nil }
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

  // MARK: - Helpers

  private static func sampleSession(
    id: UUID = UUID(),
    repositoryID: String = "/tmp/repo",
    worktreeID: String? = nil,
    displayName: String? = nil,
    removeBackingWorktreeOnDelete: Bool = false
  ) -> AgentSession {
    AgentSession(
      id: id,
      repositoryID: repositoryID,
      worktreeID: worktreeID ?? repositoryID,
      agent: .claude,
      initialPrompt: "Fix the failing tests",
      displayName: displayName,
      removeBackingWorktreeOnDelete: removeBackingWorktreeOnDelete
    )
  }
}
