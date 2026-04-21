import Foundation

private nonisolated let recorderLogger = SupaLogger("Supacool.TranscriptRecorder")

/// Per-session transcript capture. Owned as a shared `@MainActor` singleton so
/// callers from views / reducers / the terminal manager all write through a
/// single entry point. File I/O runs on a dedicated serial queue so the main
/// actor never blocks on disk.
///
/// Storage: one JSONL file per session at
/// `~/Library/Application Support/app.morethan.supacool/transcripts/<tab-uuid>.jsonl`.
/// One line = one `TranscriptEntry`. Append-only; rotation is a future concern.
///
/// This recorder is deliberately ignorant of agent type. For Claude sessions
/// there's a richer native transcript at `~/.claude/projects/.../...jsonl` —
/// `SessionReferenceScannerLive` is the thing that reads it. This file is the
/// unified, agent-agnostic view.
///
/// Not `@Observable` — nothing in the UI reads its state; it's a background
/// sink. Keeping it a plain class also avoids the `lazy`-vs-macro clash the
/// Observation macro generates.
@MainActor
final class TranscriptRecorder {
  static let shared = TranscriptRecorder()

  private let fileManager = FileManager.default
  private let writeQueue = DispatchQueue(label: "app.morethan.supacool.transcript", qos: .utility)
  private let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    // JSONL — one object per line, no pretty-print newlines inside.
    e.outputFormatting = [.withoutEscapingSlashes]
    return e
  }()

  /// Last-known output text per tab, for delta computation.
  private var lastOutputByTab: [TerminalTabID: String] = [:]

  /// Resolved transcripts directory, lazily created on first use.
  private lazy var transcriptsDirectory: URL? = {
    guard
      let base = try? fileManager.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )
    else {
      recorderLogger.warning("Could not resolve applicationSupportDirectory; transcripts disabled")
      return nil
    }
    let dir = base
      .appending(path: "app.morethan.supacool", directoryHint: .isDirectory)
      .appending(path: "transcripts", directoryHint: .isDirectory)
    do {
      try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
    } catch {
      recorderLogger.warning("Failed to create transcripts dir at \(dir.path): \(error)")
      return nil
    }
    return dir
  }()

  private init() {}

  /// Append one input chunk. Caller guarantees this is safe to log (i.e. we
  /// are NOT inside a secure-input prompt — that gating lives at the call
  /// site so this recorder stays oblivious to Ghostty state).
  func appendInput(tabID: TerminalTabID, text: String, at now: Date = Date()) {
    guard !text.isEmpty else { return }
    enqueueWrite(tabID: tabID, entry: .input(text: text, at: now))
  }

  /// Record the terminal surface at an idle boundary. `fullText` is the
  /// entire scrollback + visible content as returned by
  /// `ghostty_surface_read_text` with `GHOSTTY_POINT_SURFACE`. The recorder
  /// computes the delta against the last snapshot for the same tab.
  func snapshotOutput(tabID: TerminalTabID, fullText: String, at now: Date = Date()) {
    let previous = lastOutputByTab[tabID] ?? ""
    let delta = TranscriptDelta.compute(previous: previous, next: fullText)
    // Skip writing if nothing new — busy→idle edges can fire with no visible
    // change (e.g. agent cleared the screen and redrew identical content).
    guard !delta.isEmpty else { return }
    lastOutputByTab[tabID] = fullText
    enqueueWrite(tabID: tabID, entry: .outputTurn(fullText: fullText, delta: delta, at: now))
  }

  /// Forget a session — called when the user deletes a session card. Clears
  /// the in-memory delta state; the JSONL file on disk stays (user can
  /// grep / archive / delete externally).
  func forget(tabID: TerminalTabID) {
    lastOutputByTab.removeValue(forKey: tabID)
  }

  /// Absolute path to the transcript file for a given tab. Exposed so a
  /// future "Open transcript" UI affordance can reveal it in Finder.
  func transcriptURL(tabID: TerminalTabID) -> URL? {
    transcriptsDirectory?
      .appending(path: "\(tabID.rawValue.uuidString).jsonl", directoryHint: .notDirectory)
  }

  // MARK: - Private

  private func enqueueWrite(tabID: TerminalTabID, entry: TranscriptEntry) {
    guard let url = transcriptURL(tabID: tabID) else { return }
    let encoder = self.encoder
    writeQueue.async {
      do {
        let data = try encoder.encode(entry)
        // JSONL: one line per entry. Append; create the file with the first
        // write so we don't need a separate init step per session.
        var line = data
        line.append(0x0A)  // newline
        if FileManager.default.fileExists(atPath: url.path) {
          let handle = try FileHandle(forWritingTo: url)
          defer { try? handle.close() }
          try handle.seekToEnd()
          try handle.write(contentsOf: line)
        } else {
          try line.write(to: url, options: .atomic)
        }
      } catch {
        recorderLogger.warning("Transcript write failed for tab \(tabID.rawValue): \(error)")
      }
    }
  }
}
