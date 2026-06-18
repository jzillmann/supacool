import Foundation

/// Directory-backed board storage: one folder per session at
/// `<dir>/<session-id>/session.json`.
///
/// This replaces the single global `agent-sessions.json` array. The board is
/// *derived* by scanning the directory, so there is no authoritative global
/// list to clobber: a bad write, a racing instance, or an undecodable record
/// damages exactly one session instead of wiping the whole board (the
/// 2026-06-18 failure mode). Writes are per-session and atomic, so two
/// instances editing different sessions never collide, and only changed
/// sessions are rewritten (not the entire board on every keystroke).
///
/// **Ordering** is priority-first, then most-recently-updated-first. "Updated"
/// is the session file's modification time: `save` rewrites a file only when
/// its content actually changes, so an edited session bumps to the top while
/// untouched ones keep their place. This needs no extra field on
/// `AgentSession`, so the reducer's `[AgentSession]` read API is unchanged.
///
/// All I/O goes through `FileManager`; the directory is a parameter so the
/// whole thing is unit-testable against a temp dir.
nonisolated enum SessionDirectoryStore {
  private static let logger = SupaLogger("SessionStore")
  static let sessionFileName = "session.json"

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

  private static func sessionFile(for id: UUID, in directory: URL) -> URL {
    directory
      .appending(path: id.uuidString, directoryHint: .isDirectory)
      .appending(path: sessionFileName, directoryHint: .notDirectory)
  }

  // MARK: Load

  /// Every decodable session, ordered (priority desc, updated desc). An
  /// undecodable file is logged and skipped — it never fails the whole load.
  static func load(from directory: URL) -> [AgentSession] {
    loadWithTimestamps(from: directory)
      .sorted { lhs, rhs in
        if lhs.session.isPriority != rhs.session.isPriority {
          return lhs.session.isPriority
        }
        return lhs.updatedAt > rhs.updatedAt
      }
      .map(\.session)
  }

  private static func loadWithTimestamps(from directory: URL) -> [(session: AgentSession, updatedAt: Date)] {
    let fileManager = FileManager.default
    guard
      let folders = try? fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
      )
    else { return [] }

    let decoder = makeDecoder()
    var result: [(AgentSession, Date)] = []
    for folder in folders {
      let file = folder.appending(path: sessionFileName, directoryHint: .notDirectory)
      guard let data = try? Data(contentsOf: file) else { continue }
      guard let session = try? decoder.decode(AgentSession.self, from: data) else {
        logger.warning("Skipping undecodable session at \(folder.lastPathComponent)")
        continue
      }
      let modified =
        (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        ?? session.createdAt
      result.append((session, modified))
    }
    return result
  }

  // MARK: Save

  /// Syncs the directory to `sessions`: writes changed session files (atomic,
  /// content-compared so unchanged files keep their mtime/order) and removes
  /// the folders of sessions no longer present. The removed sessions are
  /// reported to `recordRemovals` **before** their folders are deleted, so a
  /// caller can back them up crash-safely. Never throws.
  static func save(
    _ sessions: [AgentSession],
    to directory: URL,
    recordRemovals: ([AgentSession]) -> Void = { _ in }
  ) {
    let fileManager = FileManager.default
    try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

    let onDisk = Dictionary(
      loadWithTimestamps(from: directory).map { ($0.session.id.uuidString, $0.session) },
      uniquingKeysWith: { first, _ in first }
    )
    let keepIDs = Set(sessions.map(\.id.uuidString))

    // Record + remove sessions dropped from the board. Record first so a
    // crash mid-delete still leaves them recoverable.
    let removed = onDisk.filter { !keepIDs.contains($0.key) }.map(\.value)
    if !removed.isEmpty {
      recordRemovals(removed)
      for id in removed.map(\.id.uuidString) {
        try? fileManager.removeItem(
          at: directory.appending(path: id, directoryHint: .isDirectory)
        )
      }
    }

    // Write changed sessions only — a byte-identical file is left untouched
    // so its mtime (and therefore its position in the ordering) is stable.
    let encoder = makeEncoder()
    for session in sessions {
      guard let data = try? encoder.encode(session) else { continue }
      let file = sessionFile(for: session.id, in: directory)
      if let current = try? Data(contentsOf: file), current == data { continue }
      try? fileManager.createDirectory(
        at: file.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try? data.write(to: file, options: [.atomic])
    }
  }

  // MARK: Migration

  /// One-time import of the legacy single-file board into the per-session
  /// directory. No-op once any session folder exists. Stamps each migrated
  /// file's mtime from the session's latest activity so the initial ordering
  /// reflects real recency, then renames the legacy file aside so it is never
  /// re-imported.
  static func migrateLegacyFileIfNeeded(from legacyFile: URL, to directory: URL) {
    let fileManager = FileManager.default
    if !load(from: directory).isEmpty { return }
    guard
      let data = try? Data(contentsOf: legacyFile),
      let sessions = try? makeDecoder().decode([AgentSession].self, from: data),
      !sessions.isEmpty
    else { return }

    save(sessions, to: directory)
    for session in sessions {
      let updatedAt = session.terminals.map(\.lastActivityAt).max() ?? session.createdAt
      let file = sessionFile(for: session.id, in: directory)
      try? fileManager.setAttributes(
        [.modificationDate: updatedAt],
        ofItemAtPath: file.path(percentEncoded: false)
      )
    }
    try? fileManager.moveItem(at: legacyFile, to: legacyFile.appendingPathExtension("migrated"))
    logger.info("Migrated \(sessions.count) session(s) from agent-sessions.json to per-session storage")
  }
}
