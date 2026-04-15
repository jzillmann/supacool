import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import Supacool

@MainActor
struct BoardFeatureTests {
  // MARK: - Session CRUD

  @Test(.dependencies) func createSessionAddsToListAndFocuses() async {
    let store = TestStore(initialState: BoardFeature.State()) {
      BoardFeature()
    }
    let session = Self.sampleSession()

    // createSession intentionally does NOT focus the new card — the user
    // stays on the board and sees it appear in "In Progress."
    await store.send(.createSession(session)) {
      $0.$sessions.withLock { $0 = [session] }
    }
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

  @Test(.dependencies) func visibleSessionsFiltersByRepo() async {
    let sessionA = Self.sampleSession(repositoryID: "/tmp/a")
    let sessionB = Self.sampleSession(repositoryID: "/tmp/b")
    var state = BoardFeature.State()
    state.$sessions.withLock { $0 = [sessionA, sessionB] }
    state.$filters.withLock { $0.selectedRepositoryIDs = ["/tmp/a"] }

    #expect(state.visibleSessions.map(\.id) == [sessionA.id])
    #expect(state.filters.includes(repositoryID: "/tmp/a"))
    #expect(!state.filters.includes(repositoryID: "/tmp/b"))
  }

  @Test(.dependencies) func visibleSessionsShowsAllWhenFilterEmpty() async {
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

  // MARK: - Helpers

  private static func sampleSession(
    id: UUID = UUID(),
    repositoryID: String = "/tmp/repo",
    displayName: String? = nil
  ) -> AgentSession {
    AgentSession(
      id: id,
      repositoryID: repositoryID,
      worktreeID: repositoryID,
      agent: .claude,
      initialPrompt: "Fix the failing tests",
      displayName: displayName
    )
  }
}
