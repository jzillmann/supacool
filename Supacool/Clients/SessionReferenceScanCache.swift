import Foundation

private nonisolated let scanCacheLogger = SupaLogger("Supacool.SessionReferenceScanCache")

/// Scans transcripts for references incrementally: each file is read once,
/// and later scans only read the lines appended since.
///
/// The board rescans a session every time its activity stamp moves, which is
/// constantly while an agent works. Reading and regex-scanning the whole file
/// each time scaled with the transcript, and terminal transcripts reach
/// hundreds of MB — a handful of busy sessions kept several cores busy and
/// held gigabytes of transient copies. The cache keeps the read offset and
/// the running tallies per file, so a rescan costs only the new bytes.
///
/// One actor for all files on purpose: scans run one at a time, so a burst
/// of activity edges queues up instead of fanning out across every core.
/// The state lives in memory only; after a relaunch the first scan of each
/// file is a full (chunked) read.
actor SessionReferenceScanCache {
  static let shared = SessionReferenceScanCache()

  private struct Entry<Accumulator> {
    var fileNumber: Int?
    var offset: UInt64
    var accumulator: Accumulator
  }

  private var claudeJSONL: [URL: Entry<ClaudeJSONLReferenceAccumulator>] = [:]
  private var terminalTranscripts: [URL: Entry<TerminalTranscriptReferenceAccumulator>] = [:]

  func scanClaudeJSONL(at url: URL, allowedPrefixes: Set<String>) -> SessionReferenceScan {
    advance(&claudeJSONL[url], url: url, make: { ClaudeJSONLReferenceAccumulator(allowedPrefixes: allowedPrefixes) })
      .scan
  }

  func scanTerminalTranscript(at url: URL, allowedPrefixes: Set<String>) -> [SessionReference] {
    advance(
      &terminalTranscripts[url],
      url: url,
      make: { TerminalTranscriptReferenceAccumulator(allowedPrefixes: allowedPrefixes) }
    )
    .references
  }

  /// Feeds the lines appended since the last scan into the entry's
  /// accumulator. Starts over when the file was replaced or shrank, or when
  /// the scan scope (`make`'s prefixes) changed.
  private func advance<Accumulator: LineReferenceAccumulator>(
    _ entry: inout Entry<Accumulator>?,
    url: URL,
    make: () -> Accumulator
  ) -> Accumulator {
    let fresh = make()
    let fileNumber = Self.fileNumber(of: url)
    guard let fileNumber else {
      entry = nil
      return fresh
    }
    var current = entry ?? Entry(fileNumber: fileNumber, offset: 0, accumulator: fresh)
    if current.fileNumber != fileNumber || current.accumulator.allowedPrefixes != fresh.allowedPrefixes {
      current = Entry(fileNumber: fileNumber, offset: 0, accumulator: fresh)
    }
    var accumulator = current.accumulator
    if let offset = forEachLine(in: url, from: current.offset, { accumulator.consume(line: $0) }) {
      current.offset = offset
      current.accumulator = accumulator
    } else {
      scanCacheLogger.info("Transcript shrank, rescanning from the start: \(url.lastPathComponent)")
      var restarted = fresh
      current.offset = forEachLine(in: url, from: 0, { restarted.consume(line: $0) }) ?? 0
      current.accumulator = restarted
    }
    entry = current
    return current.accumulator
  }

  private static func fileNumber(of url: URL) -> Int? {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
    return (attributes?[.systemFileNumber] as? NSNumber)?.intValue
  }
}

/// Calls `body` with each complete line from byte `offset` on, reading in
/// bounded chunks so a large file never sits in memory whole. A trailing line
/// without its newline is left for the next call — the writer may still be
/// mid-line. Returns the offset just past the last complete line, or nil when
/// the file is shorter than `offset` (truncated or replaced).
nonisolated func forEachLine(
  in url: URL,
  from offset: UInt64,
  chunkSize: Int = 8 << 20,
  _ body: (Data) -> Void
) -> UInt64? {
  guard let handle = try? FileHandle(forReadingFrom: url) else { return offset }
  defer { try? handle.close() }
  guard let end = try? handle.seekToEnd() else { return offset }
  guard end >= offset else { return nil }
  guard (try? handle.seek(toOffset: offset)) != nil else { return offset }
  let newline = UInt8(ascii: "\n")
  var consumed = offset
  var pending = Data()
  while let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty {
    pending.append(chunk)
    guard let lastNewline = pending.lastIndex(of: newline) else { continue }
    for line in pending[pending.startIndex..<lastNewline].split(separator: newline) where !line.isEmpty {
      body(Data(line))
    }
    consumed += UInt64(pending.distance(from: pending.startIndex, to: lastNewline) + 1)
    pending = Data(pending[pending.index(after: lastNewline)...])
  }
  return consumed
}

/// Running reference tallies fed one transcript line at a time.
nonisolated protocol LineReferenceAccumulator: Sendable {
  var allowedPrefixes: Set<String> { get }
  mutating func consume(line: Data)
}

/// First-seen order plus the signal-vs-noise counts both transcript formats
/// share: a reference seen in high-signal text is kept at once; one seen only
/// in noisy output must recur in ≥ 2 separate output blocks.
nonisolated struct ReferenceTally: Sendable {
  private var firstSeen: [String: SessionReference] = [:]
  private var order: [String] = []
  private var highSignalKeys = Set<String>()
  private var noisyBlockCounts: [String: Int] = [:]

  mutating func observeHighSignal(_ refs: [SessionReference]) {
    for ref in refs {
      record(ref)
      highSignalKeys.insert(ref.dedupeKey)
    }
  }

  /// `refs` from one output block; a reference counts once per block.
  mutating func observeNoisyBlock(_ refs: [SessionReference]) {
    var seenInBlock = Set<String>()
    for ref in refs {
      record(ref)
      if seenInBlock.insert(ref.dedupeKey).inserted {
        noisyBlockCounts[ref.dedupeKey, default: 0] += 1
      }
    }
  }

  /// Kept references in first-seen order. `alwaysKeep` clears the noise bar
  /// regardless of counts (a PR the session created).
  func references(alwaysKeep: Set<String> = []) -> [SessionReference] {
    order.compactMap { key in
      guard let ref = firstSeen[key] else { return nil }
      if highSignalKeys.contains(key) || alwaysKeep.contains(key) { return ref }
      return (noisyBlockCounts[key] ?? 0) >= 2 ? ref : nil
    }
  }

  private mutating func record(_ ref: SessionReference) {
    if firstSeen[ref.dedupeKey] == nil {
      firstSeen[ref.dedupeKey] = ref
      order.append(ref.dedupeKey)
    }
  }
}

/// Claude Code's native JSONL. See `SessionReferenceScannerLive.scanJSONL`
/// for the signal-vs-noise rules and `scanJSONLDetailed` for creation.
nonisolated struct ClaudeJSONLReferenceAccumulator: LineReferenceAccumulator {
  let allowedPrefixes: Set<String>
  private var tally = ReferenceTally()
  private var createToolUseIDs = Set<String>()
  private var createdKeys = Set<String>()

  init(allowedPrefixes: Set<String>) {
    self.allowedPrefixes = allowedPrefixes
  }

  var scan: SessionReferenceScan {
    SessionReferenceScan(
      references: tally.references(alwaysKeep: createdKeys),
      createdPullRequestKeys: createdKeys
    )
  }

  mutating func consume(line: Data) {
    guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
      let kind = obj["type"] as? String, kind == "user" || kind == "assistant",
      let message = obj["message"] as? [String: Any]
    else { return }
    typealias Live = SessionReferenceScannerLive
    let content = message["content"]
    createToolUseIDs.formUnion(Live.pullRequestCreationToolUseIDs(in: content))
    for ref in Live.pullRequestsCreated(in: content, byToolUseIDs: createToolUseIDs) {
      createdKeys.insert(ref.dedupeKey)
    }
    let (highSignal, toolResult) = Live.partitionText(from: content)
    tally.observeHighSignal(Live.scanText(highSignal, allowedPrefixes: allowedPrefixes))
    tally.observeNoisyBlock(Live.scanText(toolResult, allowedPrefixes: allowedPrefixes))
  }
}

/// Supacool's own terminal transcript (`TranscriptEntry` lines). See
/// `SessionReferenceScannerLive.scanTranscriptEntries` for the rules.
nonisolated struct TerminalTranscriptReferenceAccumulator: LineReferenceAccumulator {
  let allowedPrefixes: Set<String>
  private var tally = ReferenceTally()
  private let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }()

  init(allowedPrefixes: Set<String>) {
    self.allowedPrefixes = allowedPrefixes
  }

  var references: [SessionReference] { tally.references() }

  mutating func consume(line: Data) {
    guard let entry = try? decoder.decode(TranscriptEntry.self, from: line) else { return }
    consume(entry)
  }

  mutating func consume(_ entry: TranscriptEntry) {
    let prefixes = allowedPrefixes
    let scan = { (text: String) in SessionReferenceScannerLive.scanText(text, allowedPrefixes: prefixes) }
    switch entry {
    case .input(let text, _):
      tally.observeHighSignal(scan(text))
    case .outputTurn(_, let delta, _):
      tally.observeNoisyBlock(scan(delta))
    case .hookEvent(_, _, let title, let body, _, _, _, _):
      if let title { tally.observeHighSignal(scan(title)) }
      if let body { tally.observeHighSignal(scan(body)) }
    default:
      return
    }
  }
}
