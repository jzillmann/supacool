import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import Supacool

/// Keeps transcript files small and few: deltas realign after a scrollback
/// trim, output turns are capped, and unused files are swept at launch.
@MainActor
struct TranscriptHousekeepingTests {
  // MARK: - TranscriptDelta

  @Test func deltaAfterScrollbackTrimIsOnlyTheNewTail() {
    let kept = String(repeating: "line of output\n", count: 100)
    let previous = "old head that scrolls away\n" + kept
    let next = kept + "the agent's new answer\n"
    #expect(TranscriptDelta.compute(previous: previous, next: next) == "the agent's new answer\n")
  }

  @Test func deltaIsCappedToTheNewestText() {
    let huge = String(repeating: "x", count: TranscriptDelta.maxCharacters) + "END"
    let delta = TranscriptDelta.compute(previous: "", next: huge)
    #expect(delta.hasPrefix("…[truncated]…\n"))
    #expect(delta.hasSuffix("END"))
    #expect(delta.count == TranscriptDelta.maxCharacters + "…[truncated]…\n".count)
  }

  @Test func outputTurnWithoutFullTextOmitsTheField() throws {
    let entry = TranscriptEntry.outputTurn(fullText: "", delta: "hi", at: Date(timeIntervalSince1970: 1))
    let json = try #require(String(bytes: JSONEncoder().encode(entry), encoding: .utf8))
    #expect(!json.contains("fullText"))
    #expect(try JSONDecoder().decode(TranscriptEntry.self, from: Data(json.utf8)) == entry)
  }

  // MARK: - sweepTranscripts

  @Test func sweepDeletesOnlyStaleUnusedTranscripts() throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "transcripts-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let now = Date()
    let old = now.addingTimeInterval(-30 * 24 * 60 * 60)
    func write(_ name: String, modified: Date) throws -> URL {
      let url = directory.appending(path: name, directoryHint: .notDirectory)
      try Data("{}\n".utf8).write(to: url)
      try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
      return url
    }
    let kept = UUID()
    let staleUnused = try write("\(UUID().uuidString).jsonl", modified: old)
    let staleKept = try write("\(kept.uuidString).jsonl", modified: old)
    let freshUnused = try write("\(UUID().uuidString).jsonl", modified: now)
    let foreign = try write("notes.jsonl", modified: old)

    let deleted = sweepTranscripts(in: directory, keep: [kept], modifiedBefore: now.addingTimeInterval(-60))

    #expect(deleted == 1)
    let exists = { (url: URL) in FileManager.default.fileExists(atPath: url.path) }
    #expect(!exists(staleUnused))
    #expect(exists(staleKept))
    #expect(exists(freshUnused))
    #expect(exists(foreign))
  }

  // MARK: - Board sweep

  @Test(.dependencies) func boardSweepKeepsEverySessionAndTrashedTerminal() async {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let pane = SessionTerminal(role: .shell, hostTabID: UUID())
    let shellTab = SessionTerminal(role: .shell)
    var live = AgentSession(repositoryID: "/tmp/repo", worktreeID: "/tmp/repo", agent: .claude, initialPrompt: "x")
    live.terminals += [shellTab, pane]
    let trashed = AgentSession(repositoryID: "/tmp/repo", worktreeID: "/tmp/repo", agent: .claude, initialPrompt: "y")
    let state = BoardFeature.State()
    state.$sessions.withLock { $0 = [live] }
    state.$trashedSessions.withLock {
      $0 = [
        TrashedSession(
          session: trashed, repositoryID: "/tmp/repo", worktreeID: "/tmp/repo",
          deleteBackingWorktree: false, additionalWorktreeIDsToDelete: [], trashedAt: now
        ),
      ]
    }
    let swept = LockIsolated<[(Set<UUID>, Date)]>([])
    let store = TestStore(initialState: state) {
      BoardFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.transcriptStore.sweep = { keep, before in
        swept.withValue { $0.append((keep, before)) }
        return 0
      }
    }

    await store.send(._sweepStaleTranscripts)
    await store.finish()

    let call = swept.value.first
    #expect(swept.value.count == 1)
    #expect(call?.0 == Set([live.id, shellTab.id, pane.id, pane.hostTabID, trashed.id].compactMap(\.self)))
    #expect(call?.1 == now.addingTimeInterval(-BoardFeature.transcriptStaleAge))
  }

  @Test(.dependencies) func boardSweepSkipsAnEmptyBoard() async {
    let swept = LockIsolated(false)
    let store = TestStore(initialState: BoardFeature.State()) {
      BoardFeature()
    } withDependencies: {
      $0.transcriptStore.sweep = { _, _ in
        swept.setValue(true)
        return 0
      }
    }
    await store.send(._sweepStaleTranscripts)
    #expect(!swept.value)
  }
}
