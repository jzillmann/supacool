import Foundation

/// One crash-safety snapshot: the board sessions that disappeared in a
/// single persistence write, plus when it happened.
///
/// `AgentSessionsKey` records one of these *before* it overwrites
/// `agent-sessions.json` with a smaller set, so a session can never be
/// silently lost to a crash mid-mutation (the failure mode behind the
/// 2026-06-04 SIGABRT). Launch self-heal re-adopts any recorded session
/// that left the board *without* being trashed.
nonisolated struct RemovedSessionsSnapshot: Codable, Equatable, Sendable {
  var removedAt: Date
  var sessions: [AgentSession]

  init(removedAt: Date, sessions: [AgentSession]) {
    self.removedAt = removedAt
    self.sessions = sessions
  }

  // Forward-compatible decode (see docs/agent-guides/persistence.md): a new
  // field must never wipe an existing recovery file on read.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    removedAt = try container.decodeIfPresent(Date.self, forKey: .removedAt) ?? Date()
    sessions = try container.decodeIfPresent([AgentSession].self, forKey: .sessions) ?? []
  }
}

/// Bounded store of recently removed board sessions. All I/O goes through
/// `SettingsFileStorage` (no direct `FileManager`) so it is unit-testable
/// with the in-memory storage and inherits the same atomic-write guarantees
/// as the other Supacool persistence keys.
nonisolated enum SessionRecoveryStore {
  private static let logger = SupaLogger("SessionRecovery")

  static var fileURL: URL {
    SupacoolPaths.baseDirectory.appending(
      path: "agent-sessions-recovery.json",
      directoryHint: .notDirectory
    )
  }

  /// Keep the store bounded. Snapshots age out once launch self-heal has had
  /// a chance to consume them; this cap is the hard backstop against a
  /// pathological churn loop growing the file without limit.
  static let maxSnapshots = 50

  private static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  private static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }

  /// Records any session present in `previous` but absent from `next`.
  /// No-op when nothing was removed. Never throws — the backstop must not be
  /// able to break the primary session save, so failures are logged only.
  /// Returns the sessions it recorded (for callers/tests).
  @discardableResult
  static func recordRemovals(
    previous: [AgentSession],
    next: [AgentSession],
    storage: SettingsFileStorage,
    now: Date = Date()
  ) -> [AgentSession] {
    let nextIDs = Set(next.map(\.id))
    let removed = previous.filter { !nextIDs.contains($0.id) }
    guard !removed.isEmpty else { return [] }

    var snapshots = loadSnapshots(storage: storage)
    snapshots.append(RemovedSessionsSnapshot(removedAt: now, sessions: removed))
    if snapshots.count > maxSnapshots {
      snapshots.removeFirst(snapshots.count - maxSnapshots)
    }
    write(snapshots, storage: storage)
    logger.info("Recorded \(removed.count) removed session(s) to the recovery store")
    return removed
  }

  static func loadSnapshots(storage: SettingsFileStorage) -> [RemovedSessionsSnapshot] {
    guard let data = try? storage.load(fileURL) else { return [] }
    return (try? makeDecoder().decode([RemovedSessionsSnapshot].self, from: data)) ?? []
  }

  /// Overwrites the store. Used by launch self-heal to drop snapshots it has
  /// finished consuming. Failures are logged, not thrown.
  static func write(_ snapshots: [RemovedSessionsSnapshot], storage: SettingsFileStorage) {
    do {
      try storage.save(makeEncoder().encode(snapshots), fileURL)
    } catch {
      logger.warning("Failed to write session recovery store: \(error)")
    }
  }
}
