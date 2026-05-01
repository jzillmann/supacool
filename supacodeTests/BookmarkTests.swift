import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import Supacool

@MainActor
struct BookmarkTests {
  // MARK: - Forward-compatible decoding

  @Test func decodingMissingOptionalFieldsFallsBackToDefaults() throws {
    let json = """
      {
        "id": "00000000-0000-0000-0000-000000000001",
        "repositoryID": "/tmp/repo",
        "name": "Investigate",
        "prompt": "/investigate"
      }
      """
    let data = Data(json.utf8)
    let bookmark = try JSONDecoder().decode(Bookmark.self, from: data)

    #expect(bookmark.id == UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
    #expect(bookmark.repositoryID == "/tmp/repo")
    #expect(bookmark.name == "Investigate")
    #expect(bookmark.prompt == "/investigate")
    #expect(bookmark.agent == nil)
    #expect(bookmark.worktreeMode == .repoRoot)
    #expect(bookmark.planMode == false)
  }

  @Test func encodingThenDecodingRoundTripsAllFields() throws {
    let created = Date(timeIntervalSince1970: 1_700_000_000)
    let original = Bookmark(
      id: UUID(),
      repositoryID: "/tmp/repo",
      name: "CI Triage",
      prompt: "/ci-triage regression",
      agent: .claude,
      worktreeMode: .newWorktree,
      planMode: true,
      createdAt: created
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let data = try encoder.encode(original)
    let decoded = try decoder.decode(Bookmark.self, from: data)
    #expect(decoded == original)
  }

  // MARK: - Worktree name generation

  @Test func generateWorktreeNameSlugifiesAndStampsMinute() {
    let bookmark = Self.sampleBookmark(name: "CI Triage: Regression!")
    // Deterministic date: 2026-04-24 15:30 local.
    var components = DateComponents()
    components.year = 2026
    components.month = 4
    components.day = 24
    components.hour = 15
    components.minute = 30
    let now = Calendar(identifier: .gregorian).date(from: components)!

    let name = bookmark.generateWorktreeName(now: now)
    #expect(name.hasPrefix("ci-triage-regression-"))
    #expect(name.hasSuffix("-202604\(String(format: "%02d", 24))-1530") || name.contains("-20260424-1530"))
  }

  @Test func generateWorktreeNameFallsBackWhenSlugEmpty() {
    let bookmark = Self.sampleBookmark(name: "!!!")
    let name = bookmark.generateWorktreeName(now: Date(timeIntervalSince1970: 0))
    #expect(name.hasPrefix("bookmark-"))
  }

  // MARK: - Bookmark save delegate → BoardFeature

  @Test(.dependencies) func bookmarkSavedAppendsWhenNew() async {
    let bookmark = Self.sampleBookmark()
    let store = TestStore(
      initialState: {
        var state = BoardFeature.State()
        // `.bookmarkSaved` only ever fires while the NewTerminalSheet
        // is presented — the TCA `ifLet` contract requires destination
        // state to be non-nil for a `.presented(…)` action to land.
        state.newTerminalSheet = NewTerminalFeature.State(
          availableRepositories: []
        )
        return state
      }()
    ) {
      BoardFeature()
    }
    store.exhaustivity = .off

    await store.send(
      .newTerminalSheet(.presented(.delegate(.bookmarkSaved(bookmark))))
    ) {
      $0.$bookmarks.withLock { $0 = [bookmark] }
    }
  }

  @Test(.dependencies) func bookmarkSavedReplacesWhenIDMatches() async {
    let id = UUID()
    let original = Self.sampleBookmark(id: id, name: "Original")
    let edited = Self.sampleBookmark(id: id, name: "Edited")
    let other = Self.sampleBookmark(name: "Other")

    let store = TestStore(
      initialState: {
        var state = BoardFeature.State()
        state.$bookmarks.withLock { $0 = [original, other] }
        state.newTerminalSheet = NewTerminalFeature.State(
          availableRepositories: []
        )
        return state
      }()
    ) {
      BoardFeature()
    }
    store.exhaustivity = .off

    await store.send(
      .newTerminalSheet(.presented(.delegate(.bookmarkSaved(edited))))
    ) {
      $0.$bookmarks.withLock { $0 = [edited, other] }
    }
  }

  // MARK: - Delete

  @Test(.dependencies) func bookmarkDeleteRequestedRemovesMatching() async {
    let first = Self.sampleBookmark(name: "A")
    let second = Self.sampleBookmark(name: "B")
    let store = TestStore(
      initialState: {
        var state = BoardFeature.State()
        state.$bookmarks.withLock { $0 = [first, second] }
        return state
      }()
    ) {
      BoardFeature()
    }

    await store.send(.bookmarkDeleteRequested(id: first.id)) {
      $0.$bookmarks.withLock { $0 = [second] }
    }
  }

  // MARK: - Edit request opens the sheet pre-filled

  @Test(.dependencies) func bookmarkEditRequestedOpensSheetWithEditingID() async {
    let bookmark = Self.sampleBookmark(
      name: "Investigate",
      prompt: "/investigate",
      agent: .claude,
      worktreeMode: .repoRoot
    )
    let repo = Self.sampleRepository(id: bookmark.repositoryID)
    let store = TestStore(
      initialState: {
        var state = BoardFeature.State()
        state.$bookmarks.withLock { $0 = [bookmark] }
        return state
      }()
    ) {
      BoardFeature()
    }
    store.exhaustivity = .off

    await store.send(.bookmarkEditRequested(id: bookmark.id, repositories: [repo]))

    let sheet = store.state.newTerminalSheet
    #expect(sheet != nil)
    #expect(sheet?.editingBookmarkID == bookmark.id)
    #expect(sheet?.saveAsBookmark == true)
    #expect(sheet?.bookmarkName == "Investigate")
    #expect(sheet?.prompt == "/investigate")
    #expect(sheet?.agent == .claude)
  }

  // MARK: - Launch availability

  @Test func unavailableBookmarkIDsIncludesInFlightAndLiveIncarnations() {
    let inFlight = Self.sampleBookmark(name: "InFlight")
    let live = Self.sampleBookmark(name: "Live")

    var state = BoardFeature.State()
    state.bookmarkSpawnInFlight.insert(inFlight.id)
    state.$sessions.withLock {
      $0 = [Self.sampleSession(repositoryID: live.repositoryID, sourceBookmarkID: live.id)]
    }

    #expect(state.unavailableBookmarkIDs == [inFlight.id, live.id])
  }

  @Test(.dependencies) func bookmarkTappedIgnoredWhenSessionIncarnationAlreadyActive() async {
    let bookmark = Self.sampleBookmark()
    let active = Self.sampleSession(
      repositoryID: bookmark.repositoryID,
      sourceBookmarkID: bookmark.id
    )
    let repo = Self.sampleRepository(id: bookmark.repositoryID)

    let store = TestStore(
      initialState: {
        var state = BoardFeature.State()
        state.$bookmarks.withLock { $0 = [bookmark] }
        state.$sessions.withLock { $0 = [active] }
        return state
      }()
    ) {
      BoardFeature()
    }

    await store.send(.bookmarkTapped(id: bookmark.id, repositories: [repo])) {
      $0.$bookmarks.withLock { $0 = [bookmark] }
      $0.$sessions.withLock { $0 = [active] }
    }
  }

  @Test(.dependencies) func bookmarkTappedShowsStartingSessionCardImmediately() async {
    let sessionID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    let bookmark = Self.sampleBookmark(
      prompt: "Investigate failing CI",
      worktreeMode: .repoRoot
    )
    let repo = Self.sampleRepository(id: bookmark.repositoryID)
    let placeholder = TrayCard(
      id: sessionID,
      kind: .sessionCreating(
        sessionID: sessionID,
        displayName: AgentSession.deriveDisplayName(from: bookmark.prompt, fallbackID: sessionID)
      )
    )
    let store = TestStore(
      initialState: {
        var state = BoardFeature.State()
        state.$bookmarks.withLock { $0 = [bookmark] }
        return state
      }()
    ) {
      BoardFeature()
    } withDependencies: {
      $0.uuid = .constant(sessionID)
      $0.repoSync = RepoSyncClient(syncIfSafe: { _ in .skippedDirtyTree })
      $0.terminalClient.send = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.bookmarkTapped(id: bookmark.id, repositories: [repo])) {
      $0.bookmarkSpawnInFlight.insert(bookmark.id)
      $0.trayCards = [placeholder]
    }
    await store.receive(\._bookmarkSpawnCompleted) {
      $0.bookmarkSpawnInFlight.remove(bookmark.id)
      $0.trayCards = [placeholder]
    }
    await store.receive(\.createSession)

    #expect(store.state.sessions.count == 1)
    #expect(store.state.sessions.first?.id == sessionID)
    #expect(store.state.sessions.first?.sourceBookmarkID == bookmark.id)
    #expect(store.state.trayCards == [placeholder])
  }

  @Test(.dependencies) func bookmarkSpawnFailedClearsInFlightMarkerAndPlaceholder() async {
    let bookmarkID = UUID()
    let sessionID = UUID()
    let placeholder = TrayCard(
      id: sessionID,
      kind: .sessionCreating(sessionID: sessionID, displayName: "Investigate")
    )
    let store = TestStore(
      initialState: {
        var state = BoardFeature.State()
        state.bookmarkSpawnInFlight.insert(bookmarkID)
        state.trayCards = [placeholder]
        return state
      }()
    ) {
      BoardFeature()
    }

    await store.send(
      ._bookmarkSpawnFailed(bookmarkID: bookmarkID, sessionID: sessionID, message: "boom")
    ) {
      $0.bookmarkSpawnInFlight.remove(bookmarkID)
      $0.trayCards = []
    }
  }

  // MARK: - Helpers

  private static func sampleBookmark(
    id: UUID = UUID(),
    repositoryID: String = "/tmp/repo",
    name: String = "Sample",
    prompt: String = "/investigate",
    agent: AgentType? = .claude,
    worktreeMode: Bookmark.WorktreeMode = .repoRoot,
    planMode: Bool = false
  ) -> Bookmark {
    Bookmark(
      id: id,
      repositoryID: repositoryID,
      name: name,
      prompt: prompt,
      agent: agent,
      worktreeMode: worktreeMode,
      planMode: planMode,
      createdAt: Date(timeIntervalSince1970: 0)
    )
  }

  private static func sampleSession(
    id: UUID = UUID(),
    repositoryID: String = "/tmp/repo",
    sourceBookmarkID: Bookmark.ID? = nil
  ) -> AgentSession {
    AgentSession(
      id: id,
      repositoryID: repositoryID,
      worktreeID: repositoryID,
      agent: .claude,
      initialPrompt: "/investigate",
      sourceBookmarkID: sourceBookmarkID
    )
  }

  private static func sampleRepository(id: String = "/tmp/repo") -> Repository {
    Repository(
      id: id,
      rootURL: URL(fileURLWithPath: id),
      name: URL(fileURLWithPath: id).lastPathComponent,
      worktrees: []
    )
  }
}
