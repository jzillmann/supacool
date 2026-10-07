import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import Supacool

@MainActor
@Suite(.serialized)
struct BoardSessionNotesTests {
  private static let noteID = UUID(0)
  private static let now = Date(timeIntervalSince1970: 1_800_000_000)

  // MARK: - Reducer

  @Test(.dependencies) func pinOnTheAgentTabStoresANormalizedNote() async {
    let session = Self.sampleSession()
    let surfaceID = UUID()
    let store = Self.makeStore(sessions: [session])

    await store.send(
      .pinTerminalSelection(
        worktreeID: session.worktreeID,
        tabID: session.id,
        surfaceID: surfaceID,
        text: "\n  Proposed tickets   \n  1. Read Scribd documents  \n\n"
      )
    ) {
      $0.$sessions.withLock { sessions in
        sessions[0].notes = [
          SessionNote(
            id: Self.noteID,
            text: "  Proposed tickets\n  1. Read Scribd documents",
            terminalID: session.id,
            surfaceID: surfaceID,
            createdAt: Self.now
          ),
        ]
      }
    }
  }

  @Test(.dependencies) func pinInAnAdoptedPaneBelongsToThePaneTerminal() async {
    var session = Self.sampleSession()
    let paneID = UUID()
    session.terminals.append(
      SessionTerminal(id: paneID, role: .agent, hostTabID: session.id, agent: .claude)
    )
    let store = Self.makeStore(sessions: [session])

    await store.send(
      .pinTerminalSelection(
        worktreeID: session.worktreeID, tabID: session.id, surfaceID: paneID, text: "pane output line"
      )
    ) {
      $0.$sessions.withLock { sessions in
        sessions[0].notes = [
          SessionNote(
            id: Self.noteID, text: "pane output line", terminalID: paneID, surfaceID: paneID,
            createdAt: Self.now
          ),
        ]
      }
    }
  }

  /// Two sessions can share a worktree; the tab id picks the owner.
  @Test(.dependencies) func pinResolvesTheSessionByTabNotByWorktree() async {
    let first = Self.sampleSession()
    let second = Self.sampleSession()
    let surfaceID = UUID()
    let store = Self.makeStore(sessions: [first, second])

    await store.send(
      .pinTerminalSelection(
        worktreeID: second.worktreeID, tabID: second.id, surfaceID: surfaceID, text: "second"
      )
    ) {
      $0.$sessions.withLock { sessions in
        sessions[1].notes = [
          SessionNote(
            id: Self.noteID, text: "second", terminalID: second.id, surfaceID: surfaceID,
            createdAt: Self.now
          ),
        ]
      }
    }
  }

  @Test(.dependencies) func pinFromAnUnknownTabOrBlankSelectionIsIgnored() async {
    let session = Self.sampleSession()
    let store = Self.makeStore(sessions: [session])

    await store.send(
      .pinTerminalSelection(worktreeID: session.worktreeID, tabID: UUID(), surfaceID: UUID(), text: "orphan")
    )
    await store.send(
      .pinTerminalSelection(worktreeID: session.worktreeID, tabID: session.id, surfaceID: UUID(), text: " \n \n")
    )
  }

  @Test(.dependencies) func removeNoteDropsOnlyThatNote() async {
    var session = Self.sampleSession()
    let kept = SessionNote(text: "kept", terminalID: session.id, surfaceID: session.id)
    let removed = SessionNote(text: "removed", terminalID: session.id, surfaceID: session.id)
    session.notes = [kept, removed]
    let store = Self.makeStore(sessions: [session])

    await store.send(.removeNote(sessionID: session.id, noteID: removed.id)) {
      $0.$sessions.withLock { $0[0].notes = [kept] }
    }
  }

  // MARK: - SessionNote

  @Test func searchNeedlePrefersTheFirstDistinctiveLine() {
    let note = SessionNote(
      text: "1.\n   Proposed tickets, by expected effect\n2. x", terminalID: UUID(), surfaceID: UUID()
    )
    #expect(note.searchNeedle == "Proposed tickets, by expected effect")
  }

  @Test func searchNeedleFallsBackToTheLongestShortLineAndIsCapped() {
    let short = SessionNote(text: "a\nabc\nab", terminalID: UUID(), surfaceID: UUID())
    #expect(short.searchNeedle == "abc")
    let long = SessionNote(text: String(repeating: "x", count: 200), terminalID: UUID(), surfaceID: UUID())
    #expect(long.searchNeedle?.count == SessionNote.searchNeedleCap)
    let blank = SessionNote(text: "   ", terminalID: UUID(), surfaceID: UUID())
    #expect(blank.searchNeedle == nil)
  }

  @Test func sessionWithoutNotesKeyDecodesToNoNotes() throws {
    let session = Self.sampleSession()
    var json = try #require(
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any]
    )
    json.removeValue(forKey: "notes")
    let decoded = try JSONDecoder().decode(
      AgentSession.self, from: JSONSerialization.data(withJSONObject: json)
    )
    #expect(decoded.notes.isEmpty)
  }

  @Test func notesRoundTrip() throws {
    var session = Self.sampleSession()
    session.notes = [
      SessionNote(text: "pinned", terminalID: session.id, surfaceID: UUID(), createdAt: Self.now)
    ]
    let decoded = try JSONDecoder().decode(AgentSession.self, from: JSONEncoder().encode(session))
    #expect(decoded.notes == session.notes)
  }

  // MARK: - Helpers

  private static func makeStore(sessions: [AgentSession]) -> TestStoreOf<BoardFeature> {
    let state = BoardFeature.State()
    state.$sessions.withLock { $0 = sessions }
    return TestStore(initialState: state) {
      BoardFeature()
    } withDependencies: {
      $0.uuid = .constant(noteID)
      $0.date = .constant(now)
    }
  }

  private static func sampleSession() -> AgentSession {
    AgentSession(
      repositoryID: "/tmp/repo",
      worktreeID: "/tmp/repo",
      agent: .claude,
      initialPrompt: "Find out why trace finds so few parts"
    )
  }
}
