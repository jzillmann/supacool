import ComposableArchitecture
import Foundation

/// Recovers an agent-native session id for a terminal whose hooks never
/// reported one, by reading the agent's own on-disk session store.
///
/// Hooks are the normal capture path (`captureAgentNativeSessionID`). When
/// they misroute — Codex in shared-daemon mode runs hooks with the env of
/// whichever terminal started the daemon — the terminal record never learns
/// its id, and Resume used to drop it to a blank shell. This client finds
/// the conversation by what Supacool already knows: the working directory,
/// the prompt it launched with, and when it launched.
struct NativeSessionLocatorClient: Sendable {
  struct Query: Sendable, Equatable {
    var agentID: String
    var workingDirectory: String
    var initialPrompt: String
    var createdAt: Date
  }

  /// The recovered id, or `nil` when the agent has no supported store or
  /// nothing matches unambiguously enough.
  var locate: @Sendable (Query) async -> String?
}

extension NativeSessionLocatorClient: DependencyKey {
  static let liveValue = Self(
    locate: { query in NativeSessionLocatorLive.locate(query) }
  )

  static let testValue = Self(
    locate: { _ in nil }
  )
}

// MARK: - Live implementation

private nonisolated let locatorLogger = SupaLogger("Supacool.NativeSessionLocator")

nonisolated enum NativeSessionLocatorLive {
  struct RolloutMatch: Equatable {
    let id: String
    let startedAt: Date
  }

  /// A rollout may start a little before the terminal record's `createdAt`
  /// (clock skew between the reducer stamp and Codex's own stamp).
  static let startTolerance: TimeInterval = 5 * 60

  /// Only this much of the launch prompt has to match. Long prompts can be
  /// re-wrapped or truncated by the agent; the head is distinctive enough.
  static let promptKeyLength = 400

  static func locate(_ query: NativeSessionLocatorClient.Query) -> String? {
    switch query.agentID.lowercased() {
    case "codex":
      let match = locateCodexRollout(query, sessionsRoot: codexSessionsRoot)
      if let match {
        locatorLogger.info("Recovered Codex session \(match.id) for \(query.workingDirectory)")
      }
      return match?.id
    default:
      return nil
    }
  }

  static var codexSessionsRoot: URL {
    SupacoolPaths.spawnedProcessHomeDirectory
      .appending(path: ".codex", directoryHint: .isDirectory)
      .appending(path: "sessions", directoryHint: .isDirectory)
  }

  /// Codex writes `sessions/YYYY/MM/DD/rollout-<local time>-<id>.jsonl`.
  /// Scans the launch day and its neighbours (local-time day folders, so a
  /// launch near midnight can land on either side) and picks the earliest
  /// rollout that started after the terminal was created — that is the one
  /// Supacool launched; later matches are manual relaunches with the same
  /// pasted prompt.
  static func locateCodexRollout(
    _ query: NativeSessionLocatorClient.Query,
    sessionsRoot: URL,
    calendar: Calendar = .current
  ) -> RolloutMatch? {
    let promptKey = promptKey(query.initialPrompt)
    guard !promptKey.isEmpty else { return nil }
    let notBefore = query.createdAt.addingTimeInterval(-startTolerance)
    let cwd = normalizedPath(query.workingDirectory)
    var best: RolloutMatch?
    for dayOffset in -1...1 {
      guard let day = calendar.date(byAdding: .day, value: dayOffset, to: query.createdAt) else {
        continue
      }
      let parts = calendar.dateComponents([.year, .month, .day], from: day)
      guard let year = parts.year, let month = parts.month, let dayOfMonth = parts.day else {
        continue
      }
      let directory =
        sessionsRoot
        .appending(path: "\(year)", directoryHint: .isDirectory)
        .appending(path: twoDigits(month), directoryHint: .isDirectory)
        .appending(path: twoDigits(dayOfMonth), directoryHint: .isDirectory)
      guard
        let files = try? FileManager.default.contentsOfDirectory(
          at: directory,
          includingPropertiesForKeys: nil
        )
      else { continue }
      for file in files
      where file.lastPathComponent.hasPrefix("rollout-") && file.pathExtension == "jsonl" {
        // Cheap pre-check on the first line before reading further.
        guard let metaLines = readHeadLines(of: file, maxLines: 1, maxBytes: 512 * 1024),
          let meta = metaLines.first.flatMap(parseCodexSessionMeta),
          meta.cwd == cwd, meta.startedAt >= notBefore
        else { continue }
        if let best, best.startedAt <= meta.startedAt { continue }
        guard let lines = readHeadLines(of: file, maxLines: 60, maxBytes: 4 * 1024 * 1024),
          let match = matchCodexRollout(
            lines: lines,
            workingDirectory: cwd,
            promptKey: promptKey,
            notBefore: notBefore
          )
        else { continue }
        best = match
      }
    }
    return best
  }

  /// Pure matcher over the head of one rollout file: the first line must be
  /// `session_meta` for this cwd, started no earlier than `notBefore`, and
  /// one of the first user messages must begin with the launch prompt.
  static func matchCodexRollout(
    lines: [String],
    workingDirectory: String,
    promptKey: String,
    notBefore: Date
  ) -> RolloutMatch? {
    guard let first = lines.first,
      let meta = parseCodexSessionMeta(first),
      meta.cwd == normalizedPath(workingDirectory),
      meta.startedAt >= notBefore,
      !promptKey.isEmpty
    else { return nil }
    for line in lines.dropFirst() {
      for text in codexUserMessageTexts(line) where normalizedText(text).hasPrefix(promptKey) {
        return RolloutMatch(id: meta.id, startedAt: meta.startedAt)
      }
    }
    return nil
  }

  static func promptKey(_ prompt: String) -> String {
    String(normalizedText(prompt).prefix(promptKeyLength))
  }

  // MARK: Parsing

  private struct CodexSessionMeta {
    let id: String
    let cwd: String
    let startedAt: Date
  }

  private static func parseCodexSessionMeta(_ line: String) -> CodexSessionMeta? {
    guard let object = jsonObject(line),
      object["type"] as? String == "session_meta",
      let payload = object["payload"] as? [String: Any],
      let id = payload["id"] as? String, !id.isEmpty,
      let cwd = payload["cwd"] as? String,
      let timestamp = payload["timestamp"] as? String,
      let startedAt = parseTimestamp(timestamp)
    else { return nil }
    return CodexSessionMeta(id: id, cwd: normalizedPath(cwd), startedAt: startedAt)
  }

  /// User-authored text in one rollout line. Covers both the
  /// `response_item` message shape and the `event_msg` `user_message` shape.
  private static func codexUserMessageTexts(_ line: String) -> [String] {
    guard let object = jsonObject(line),
      let payload = object["payload"] as? [String: Any]
    else { return [] }
    switch object["type"] as? String {
    case "response_item":
      guard payload["type"] as? String == "message",
        payload["role"] as? String == "user",
        let content = payload["content"] as? [[String: Any]]
      else { return [] }
      return content.compactMap { $0["text"] as? String }
    case "event_msg":
      guard payload["type"] as? String == "user_message",
        let message = payload["message"] as? String
      else { return [] }
      return [message]
    default:
      return []
    }
  }

  private static func jsonObject(_ line: String) -> [String: Any]? {
    guard let data = line.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }

  private static func parseTimestamp(_ value: String) -> Date? {
    if let date = try? Date(value, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
      return date
    }
    return try? Date(value, strategy: Date.ISO8601FormatStyle())
  }

  static func normalizedPath(_ path: String) -> String {
    let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
    guard standardized.count > 1, standardized.hasSuffix("/") else { return standardized }
    return String(standardized.dropLast())
  }

  private static func normalizedText(_ text: String) -> String {
    text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  private static func twoDigits(_ value: Int) -> String {
    value < 10 ? "0\(value)" : "\(value)"
  }

  /// Reads complete lines from the start of `url`, in 64 KB chunks, until
  /// `maxLines` lines are complete or `maxBytes` were read. Rollouts can be
  /// many MB; only their head matters here.
  private static func readHeadLines(of url: URL, maxLines: Int, maxBytes: Int) -> [String]? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    let newline = UInt8(ascii: "\n")
    var buffer = Data()
    var newlineCount = 0
    var reachedEnd = false
    while buffer.count < maxBytes, newlineCount < maxLines {
      guard let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty else {
        reachedEnd = true
        break
      }
      newlineCount += chunk.reduce(0) { $1 == newline ? $0 + 1 : $0 }
      buffer.append(chunk)
    }
    // Drop the trailing partial line: a chunk boundary can split a
    // multi-byte character there, which would fail the UTF-8 decode.
    if !reachedEnd {
      guard let lastNewline = buffer.lastIndex(of: newline) else { return nil }
      buffer = buffer.prefix(through: lastNewline)
    }
    guard let text = String(bytes: buffer, encoding: .utf8) else { return nil }
    return text.split(separator: "\n", omittingEmptySubsequences: true)
      .prefix(maxLines)
      .map(String.init)
  }
}
