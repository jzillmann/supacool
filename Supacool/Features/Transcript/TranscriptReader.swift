import Foundation

private nonisolated let readerLogger = SupaLogger("Supacool.TranscriptReader")

/// Loads and shapes per-session transcript JSONL for consumers — currently
/// just the "Recent prompts" popover that steers Ghostty's ⌘F search.
///
/// The on-disk format is one `TranscriptEntry` per line, written by
/// `TranscriptRecorder`. We decode lazily, skip malformed lines instead of
/// failing the whole file, and never block the main actor on large files —
/// callers should dispatch reads off-main.
///
/// `nonisolated` on purpose: all reads hit disk, nothing touches UI state.
nonisolated enum TranscriptReader {
  /// A reconstructed "prompt" — a burst of user keystrokes grouped by
  /// temporal adjacency. See `aggregatePrompts` for the heuristic.
  struct Prompt: Equatable, Identifiable {
    let id: Date  // bucket start — stable within a session
    let text: String
    let startedAt: Date
    let endedAt: Date
  }

  /// Returns the JSONL path for a tab. Mirrors `TranscriptRecorder.transcriptURL`
  /// so the reader doesn't need to hold a reference to the recorder.
  static func transcriptURL(tabID: TerminalTabID) -> URL? {
    guard
      let base = try? FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: false
      )
    else { return nil }
    return
      base
      .appending(path: "io.morethan.supacool", directoryHint: .isDirectory)
      .appending(path: "transcripts", directoryHint: .isDirectory)
      .appending(path: "\(tabID.rawValue.uuidString).jsonl", directoryHint: .notDirectory)
  }

  /// Load every entry for a session. Ignores malformed lines, returns
  /// `[]` if the file doesn't exist yet.
  static func loadEntries(tabID: TerminalTabID) -> [TranscriptEntry] {
    guard let url = transcriptURL(tabID: tabID),
      let data = try? Data(contentsOf: url),
      let text = String(data: data, encoding: .utf8)
    else { return [] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var entries: [TranscriptEntry] = []
    for line in text.split(whereSeparator: \.isNewline) {
      guard let lineData = line.data(using: .utf8) else { continue }
      do {
        entries.append(try decoder.decode(TranscriptEntry.self, from: lineData))
      } catch {
        readerLogger.debug("Skipping malformed transcript line: \(error)")
      }
    }
    return entries
  }

  /// Group `.input` entries into "prompts" — bursts of keystrokes separated
  /// by idle gaps.
  ///
  /// Heuristic: flush the buffer when the gap between successive inputs
  /// exceeds `idleBreak` (default 2s — long enough to absorb human typing
  /// cadence, short enough to separate distinct prompts). Prompts whose
  /// visible text is shorter than `minLength` are dropped so trivial
  /// keystrokes (single characters, quick `y`/`n` replies to confirmation
  /// dialogs) don't clutter the list.
  ///
  /// Pure function so tests can drive it without disk I/O.
  static func aggregatePrompts(
    from entries: [TranscriptEntry],
    idleBreak: TimeInterval = 2.0,
    minLength: Int = 3
  ) -> [Prompt] {
    var prompts: [Prompt] = []
    var buffer = ""
    var bucketStart: Date?
    var lastAt: Date?

    func flush() {
      defer {
        buffer = ""
        bucketStart = nil
      }
      guard let start = bucketStart, let end = lastAt else { return }
      let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
      guard trimmed.count >= minLength else { return }
      prompts.append(Prompt(id: start, text: trimmed, startedAt: start, endedAt: end))
    }

    for entry in entries {
      guard case .input(let text, let at) = entry else { continue }
      if let last = lastAt, at.timeIntervalSince(last) > idleBreak {
        flush()
      }
      if bucketStart == nil { bucketStart = at }
      buffer.append(text)
      lastAt = at
    }
    flush()

    // Newest first — the button surfaces "what did I just say?" immediately.
    return prompts.reversed()
  }
}
