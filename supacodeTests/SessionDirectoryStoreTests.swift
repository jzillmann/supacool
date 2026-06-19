import Foundation
import Testing

@testable import Supacool

@Suite struct SessionDirectoryStoreTests {
  private func tempDir() -> URL {
    FileManager.default.temporaryDirectory
      .appending(path: "sessiondir-\(UUID().uuidString)", directoryHint: .isDirectory)
  }

  private func makeSession(_ name: String, priority: Bool = false) -> AgentSession {
    AgentSession(
      repositoryID: "/repo",
      worktreeID: "/wt/\(name)",
      agent: nil,
      initialPrompt: name,
      displayName: name,
      isPriority: priority
    )
  }

  private func sessionFile(_ session: AgentSession, in dir: URL) -> URL {
    dir.appending(path: session.id.uuidString, directoryHint: .isDirectory)
      .appending(path: "session.json", directoryHint: .notDirectory)
  }

  private func setMtime(_ date: Date, _ session: AgentSession, in dir: URL) {
    try? FileManager.default.setAttributes(
      [.modificationDate: date],
      ofItemAtPath: sessionFile(session, in: dir).path(percentEncoded: false)
    )
  }

  @Test func roundTripsThroughPerSessionFiles() {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let sessionA = makeSession("a"); let sessionB = makeSession("b")

    SessionDirectoryStore.save([sessionA, sessionB], to: dir)
    let loaded = SessionDirectoryStore.load(from: dir)
    #expect(Set(loaded.map(\.id)) == Set([sessionA.id, sessionB.id]))
    // One folder per session.
    #expect(FileManager.default.fileExists(atPath: sessionFile(sessionA, in: dir).path(percentEncoded: false)))
  }

  @Test func ordersByPriorityThenRecency() {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let old = makeSession("old")
    let recent = makeSession("recent")
    let pinned = makeSession("pinned", priority: true)
    SessionDirectoryStore.save([old, recent, pinned], to: dir)

    let now = Date()
    setMtime(now.addingTimeInterval(-3600), old, in: dir)
    setMtime(now, recent, in: dir)
    setMtime(now.addingTimeInterval(-7200), pinned, in: dir)  // priority despite oldest

    let order = SessionDirectoryStore.load(from: dir).map(\.displayName)
    #expect(order == ["pinned", "recent", "old"])
  }

  @Test func removesDroppedSessionsAndRecordsThemFirst() {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let sessionA = makeSession("a"); let sessionB = makeSession("b")
    SessionDirectoryStore.save([sessionA, sessionB], to: dir)

    var recorded: [AgentSession] = []
    SessionDirectoryStore.save([sessionA], to: dir, recordRemovals: { recorded.append(contentsOf: $0) })

    #expect(recorded.map(\.id) == [sessionB.id])
    #expect(SessionDirectoryStore.load(from: dir).map(\.id) == [sessionA.id])
    #expect(!FileManager.default.fileExists(atPath: sessionFile(sessionB, in: dir).path(percentEncoded: false)))
  }

  @Test func unchangedSessionKeepsItsModificationTime() throws {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let sessionA = makeSession("a")
    SessionDirectoryStore.save([sessionA], to: dir)
    let pinnedTime = Date(timeIntervalSince1970: 1_000_000)
    setMtime(pinnedTime, sessionA, in: dir)

    // Saving the identical session must not rewrite the file (so its order is stable).
    SessionDirectoryStore.save([sessionA], to: dir)
    let mtime = try sessionFile(sessionA, in: dir)
      .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    #expect(mtime == pinnedTime)
  }

  @Test func skipsUndecodableSessionInsteadOfFailingTheLoad() throws {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let good = makeSession("good")
    SessionDirectoryStore.save([good], to: dir)
    // A corrupt session folder must not take down the whole board.
    let badFolder = dir.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: badFolder, withIntermediateDirectories: true)
    try Data("{ not json".utf8).write(to: badFolder.appending(path: "session.json"))

    #expect(SessionDirectoryStore.load(from: dir).map(\.id) == [good.id])
  }

  @Test func migratesLegacyFileOnce() throws {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let base = dir.deletingLastPathComponent()
    let legacy = base.appending(path: "legacy-\(UUID().uuidString).json", directoryHint: .notDirectory)
    defer { try? FileManager.default.removeItem(at: legacy) }

    let sessionA = makeSession("a"); let sessionB = makeSession("b")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode([sessionA, sessionB]).write(to: legacy)

    SessionDirectoryStore.migrateLegacyFileIfNeeded(from: legacy, to: dir)

    #expect(Set(SessionDirectoryStore.load(from: dir).map(\.id)) == Set([sessionA.id, sessionB.id]))
    #expect(!FileManager.default.fileExists(atPath: legacy.path(percentEncoded: false)))
    #expect(
      FileManager.default.fileExists(
        atPath: legacy.appendingPathExtension("migrated").path(percentEncoded: false)
      )
    )
    try? FileManager.default.removeItem(at: legacy.appendingPathExtension("migrated"))
  }
}
