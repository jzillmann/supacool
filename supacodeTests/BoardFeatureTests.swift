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

  @Test(.dependencies) func togglePriorityFlipsPersistedBit() async {
    let session = Self.sampleSession()
    var state = BoardFeature.State()
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
    // Trash-push always defers worktree cleanup to permanent-delete /
    // sweep — delegate flags reflect that (false / empty).
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

  @Test(.dependencies) func removeSessionCapturesOwnedWorktreeForTrash() async {
    let session = Self.sampleSession(
      repositoryID: "/tmp/repo",
      worktreeID: "/tmp/repo/wt-1",
      removeBackingWorktreeOnDelete: true
    )
    var state = BoardFeature.State()
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
      deleteBackingWorktree: true,
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
          deleteBackingWorktree: false,
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
    var state = BoardFeature.State()
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

  @Test(.dependencies) func removeSessionCapturesConvertedWorktreeForTrash() async {
    // A repo-root session that used the "convert to worktree" popover
    // has `worktreeID == repositoryID` but a divergent
    // `currentWorkspacePath`. The trash entry must remember the
    // converted path so the eventual sweep / "Delete now" cleans it up
    // rather than leaving a dangling directory.
    let session = AgentSession(
      repositoryID: "/tmp/repo",
      worktreeID: "/tmp/repo",
      currentWorkspacePath: "/tmp/repo/worktrees/feature-x",
      agent: .claude,
      initialPrompt: "Work on feature X"
    )
    var state = BoardFeature.State()
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
      additionalWorktreeIDsToDelete: ["/tmp/repo/worktrees/feature-x"],
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
          additionalWorktreeIDsToDelete: []
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
    var state = BoardFeature.State()
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
    var state = BoardFeature.State()
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
    var state = BoardFeature.State()
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
    var state = BoardFeature.State()
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

  @Test(.dependencies) func priorityTerminationPresentsAlertAndDelegates() async {
    let session = Self.sampleSession(displayName: "Deploy fix", isPriority: true)
    let alertID = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
    var state = BoardFeature.State()
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
    var state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }

    let store = TestStore(initialState: state) {
      BoardFeature()
    }

    await store.send(.prioritySessionTerminated(id: session.id, status: .detached))
    #expect(store.state.priorityTerminationAlert == nil)
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
    var state = BoardFeature.State()
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

  @Test(.dependencies) func openNewTerminalSheetInheritsWorkspaceFromFocusedSession() async {
    // After a session has been converted from repo root to a worktree
    // (`currentWorkspacePath` diverges from the immutable `worktreeID`),
    // pressing ⌘N / + inside the focused terminal should preload the
    // sheet on the NEW worktree — not reset to repo root.
    let session = AgentSession(
      repositoryID: "/tmp/repo",
      worktreeID: "/tmp/repo", // started at repo root
      currentWorkspacePath: "/tmp/repo/worktrees/feature-x", // converted
      agent: .claude,
      initialPrompt: "Fix tests"
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
      .openNewTerminalSheetInheritingFrom(id: session.id, repositories: [repo])
    )

    let sheet = store.state.newTerminalSheet
    #expect(sheet?.selectedRepositoryID == "/tmp/repo")
    #expect(sheet?.selectedWorkspace == .existingWorktree(id: "/tmp/repo/worktrees/feature-x"))
    #expect(sheet?.workspaceQuery == "feature-x")
    // Fresh prompt — inheritance copies context, not content.
    #expect(sheet?.prompt == "")
  }

  @Test(.dependencies) func convertSessionToWorktreeIgnoresEmptyBranchName() async {
    let original = Self.sampleSession(repositoryID: "/tmp/repo")
    let repo = Repository(
      id: "/tmp/repo",
      rootURL: URL(fileURLWithPath: "/tmp/repo"),
      name: "Repo",
      worktrees: []
    )
    var state = BoardFeature.State()
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
    var state = BoardFeature.State()
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
    var state = BoardFeature.State()
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
        sessions[0].lastKnownBusy = false
        sessions[0].lastBusyTransitionAt = nil
        sessions[0].lastActivityAt = now
        sessions[0].parked = false
      }
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

  @Test(.dependencies) func restoreShellSessionLayoutIgnoresAgentSessions() async {
    let session = Self.sampleSession()
    var state = BoardFeature.State()
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
    var state = BoardFeature.State()
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
    var state = BoardFeature.State()
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
      $0[0].lastKnownBusy = true
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

  private static func sessionCreatingCard(for session: AgentSession) -> TrayCard {
    TrayCard(
      id: session.id,
      kind: .sessionCreating(sessionID: session.id, displayName: session.displayName)
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
