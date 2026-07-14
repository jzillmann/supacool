import ComposableArchitecture
import Foundation

/// Extracts ticket IDs (e.g. `CEN-1234`) and GitHub PR URLs from a Claude
/// Code session's native transcript file, so the board card can surface
/// them as clickable chips.
///
/// The Claude transcript lives at `~/.claude/projects/<hashed>/<session-id>.jsonl`
/// where `<hashed>` is the session's CWD with `/` replaced by `-`. Supacool
/// also scans its own terminal transcript so Codex/raw sessions can surface
/// references beyond the initial prompt.
struct SessionReferenceScannerClient: Sendable {
  /// Read the JSONL and pull out every unique ticket/PR reference from user
  /// and assistant messages. `allowedPrefixes` scopes ticket matches to a
  /// repo's Linear team keys (empty = match any uppercase prefix). Returns
  /// `[]` if the file doesn't exist.
  var scan:
    @Sendable (_ cwdPath: String, _ agentNativeSessionID: String, _ allowedPrefixes: Set<String>) async
      -> [SessionReference]
  /// One-shot regex pass over a plain string (e.g. `session.initialPrompt`),
  /// scoped to `allowedPrefixes`.
  var scanText: @Sendable (_ text: String, _ allowedPrefixes: Set<String>) -> [SessionReference]
  /// Read Supacool's own terminal transcript JSONL and scan user input /
  /// rendered output deltas, scoped to `allowedPrefixes`. This catches Codex
  /// and raw terminal text that never lands in Claude Code's native transcript.
  var scanTerminalTranscript: @Sendable (_ tabID: UUID, _ allowedPrefixes: Set<String>) async -> [SessionReference]
}

extension SessionReferenceScannerClient: DependencyKey {
  static let liveValue = Self(
    scan: { cwdPath, agentNativeSessionID, allowedPrefixes in
      SessionReferenceScannerLive.scan(
        cwdPath: cwdPath,
        agentNativeSessionID: agentNativeSessionID,
        allowedPrefixes: allowedPrefixes
      )
    },
    scanText: { text, allowedPrefixes in
      SessionReferenceScannerLive.scanText(text, allowedPrefixes: allowedPrefixes)
    },
    scanTerminalTranscript: { tabID, allowedPrefixes in
      SessionReferenceScannerLive.scanTerminalTranscript(tabID: tabID, allowedPrefixes: allowedPrefixes)
    }
  )

  static let testValue = Self(
    scan: { _, _, _ in [] },
    scanText: { _, _ in [] },
    scanTerminalTranscript: { _, _ in [] }
  )
}

extension DependencyValues {
  var sessionReferenceScannerClient: SessionReferenceScannerClient {
    get { self[SessionReferenceScannerClient.self] }
    set { self[SessionReferenceScannerClient.self] = newValue }
  }
}

// MARK: - Live implementation

private nonisolated let scannerLogger = SupaLogger("Supacool.SessionReferenceScanner")

nonisolated enum SessionReferenceScannerLive {
  /// Claude Code's project-path hash: replace `/`, `.`, and `_` with `-`.
  /// E.g. `/Users/jz/.supacool/repos/centrum_backend/foo`
  ///   →  `-Users-jz--supacool-repos-centrum-backend-foo`.
  /// Sampled from `~/.claude/projects/` — Claude Code transforms every
  /// path separator, dot, and underscore into a dash. We learned this
  /// the loud way when no PR ever got captured for sessions whose cwd
  /// contained `.supacool/` or a `snake_case` repo name.
  static func hashProjectPath(_ path: String) -> String {
    String(path.map { "/._".contains($0) ? Character("-") : $0 })
  }

  /// Absolute path to the JSONL transcript file (best guess from the
  /// hash). Use `locateJSONLURL` for runtime reads — it falls back to a
  /// `<sessionID>.jsonl` search when the hash misses.
  static func jsonlURL(cwdPath: String, agentNativeSessionID: String) -> URL {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let hashed = hashProjectPath(cwdPath)
    return
      home
      .appending(path: ".claude", directoryHint: .isDirectory)
      .appending(path: "projects", directoryHint: .isDirectory)
      .appending(path: hashed, directoryHint: .isDirectory)
      .appending(path: "\(agentNativeSessionID).jsonl", directoryHint: .notDirectory)
  }

  /// Resolve the on-disk JSONL for a session, falling back to a directory
  /// scan when the hashed path doesn't exist. `agentNativeSessionID` is
  /// globally unique, so finding `<id>.jsonl` anywhere under
  /// `~/.claude/projects/` is safe — and it keeps PR capture working if
  /// Claude Code's path-hashing rules drift again.
  static func locateJSONLURL(cwdPath: String, agentNativeSessionID: String) -> URL? {
    let direct = jsonlURL(cwdPath: cwdPath, agentNativeSessionID: agentNativeSessionID)
    let fm = FileManager.default
    if fm.fileExists(atPath: direct.path) { return direct }
    let projectsRoot = fm.homeDirectoryForCurrentUser
      .appending(path: ".claude", directoryHint: .isDirectory)
      .appending(path: "projects", directoryHint: .isDirectory)
    guard
      let projectDirs = try? fm.contentsOfDirectory(
        at: projectsRoot, includingPropertiesForKeys: nil
      )
    else { return nil }
    let targetName = "\(agentNativeSessionID).jsonl"
    for dir in projectDirs {
      let candidate = dir.appending(path: targetName, directoryHint: .notDirectory)
      if fm.fileExists(atPath: candidate.path) {
        scannerLogger.info(
          "Recovered JSONL via fallback scan: \(candidate.path) (hash miss for \(cwdPath))"
        )
        return candidate
      }
    }
    return nil
  }

  static func scan(
    cwdPath: String,
    agentNativeSessionID: String,
    allowedPrefixes: Set<String> = []
  ) -> [SessionReference] {
    guard !agentNativeSessionID.isEmpty else { return [] }
    guard
      let url = locateJSONLURL(cwdPath: cwdPath, agentNativeSessionID: agentNativeSessionID)
    else { return [] }
    guard let data = try? Data(contentsOf: url) else {
      return []
    }
    guard let content = String(data: data, encoding: .utf8) else {
      scannerLogger.warning("JSONL was not UTF-8: \(url.path)")
      return []
    }
    return scanJSONL(content, allowedPrefixes: allowedPrefixes)
  }

  /// Parse a JSONL blob, extract message text, run reference regexes,
  /// dedupe by canonical key.
  ///
  /// Signal-vs-noise mirrors `scanTranscriptEntries`: text the user typed and
  /// prose the assistant wrote are high-signal — a single occurrence is kept.
  /// `tool_result` blocks are the noisy source: one `git log`, Linear-list, or
  /// grep dump can drop dozens of incidental ticket ids into a transcript, and
  /// because `_referencesScanned` merges cumulatively those phantom chips
  /// persist forever. So a ref that only ever appears in tool output must recur
  /// across **≥ 2 messages** to count — a real focus comes back in
  /// conversation; a one-shot in a tool dump does not.
  static func scanJSONL(_ jsonl: String, allowedPrefixes: Set<String> = []) -> [SessionReference] {
    var firstSeen: [String: SessionReference] = [:]
    var order: [String] = []
    var highSignalKeys = Set<String>()
    var toolResultMessageCounts: [String: Int] = [:]

    func recordFirstSeen(_ ref: SessionReference) {
      if firstSeen[ref.dedupeKey] == nil {
        firstSeen[ref.dedupeKey] = ref
        order.append(ref.dedupeKey)
      }
    }

    for line in jsonl.split(whereSeparator: \.isNewline) {
      guard let data = String(line).data(using: .utf8) else { continue }
      guard
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else {
        continue
      }
      guard let kind = obj["type"] as? String, kind == "user" || kind == "assistant" else {
        continue
      }
      guard let message = obj["message"] as? [String: Any] else { continue }
      let (highSignal, toolResult) = partitionText(from: message["content"])

      for ref in scanText(highSignal, allowedPrefixes: allowedPrefixes) {
        recordFirstSeen(ref)
        highSignalKeys.insert(ref.dedupeKey)
      }
      var seenInMessage = Set<String>()
      for ref in scanText(toolResult, allowedPrefixes: allowedPrefixes) {
        recordFirstSeen(ref)
        if seenInMessage.insert(ref.dedupeKey).inserted {
          toolResultMessageCounts[ref.dedupeKey, default: 0] += 1
        }
      }
    }

    return order.compactMap { key in
      guard let ref = firstSeen[key] else { return nil }
      if highSignalKeys.contains(key) { return ref }
      if (toolResultMessageCounts[key] ?? 0) >= 2 { return ref }
      return nil
    }
  }

  /// Split a message's content into high-signal text (what the user typed and
  /// the prose the assistant wrote) and low-signal `tool_result` text (command
  /// / tool output dumps). `thinking` (Claude's internal monologue) and
  /// `tool_use` (noisy tool invocations) are skipped entirely.
  static func partitionText(from content: Any?) -> (highSignal: String, toolResult: String) {
    // A plain string is a real user turn — always high-signal.
    if let str = content as? String { return (str, "") }
    guard let blocks = content as? [Any] else { return ("", "") }
    var high: [String] = []
    var tool: [String] = []
    for block in blocks {
      guard let dict = block as? [String: Any] else { continue }
      switch dict["type"] as? String {
      case "text":
        if let t = dict["text"] as? String { high.append(t) }
      case "tool_result":
        // Everything nested under a tool result is low-signal output.
        tool.append(extractText(from: dict["content"]))
      default:
        continue
      }
    }
    return (high.joined(separator: "\n"), tool.joined(separator: "\n"))
  }

  /// Recursively pull out `text` and `tool_result` content from a content
  /// value, skipping `thinking` and `tool_use`. Used for nested tool-result
  /// payloads where the high/low-signal split no longer matters (the caller
  /// has already classified the whole subtree as one or the other).
  static func extractText(from content: Any?) -> String {
    if let str = content as? String { return str }
    guard let blocks = content as? [Any] else { return "" }
    var parts: [String] = []
    for block in blocks {
      guard let dict = block as? [String: Any] else { continue }
      let blockType = dict["type"] as? String
      switch blockType {
      case "text":
        if let t = dict["text"] as? String { parts.append(t) }
      case "tool_result":
        // Nested content — recurse.
        parts.append(extractText(from: dict["content"]))
      default:
        continue
      }
    }
    return parts.joined(separator: "\n")
  }

  /// Scan Supacool's agent-agnostic terminal transcript for references.
  static func scanTerminalTranscript(
    tabID: UUID,
    allowedPrefixes: Set<String> = []
  ) -> [SessionReference] {
    scanTranscriptEntries(
      TranscriptReader.loadEntries(rawTabID: tabID),
      allowedPrefixes: allowedPrefixes
    )
  }

  /// Pure transcript-entry scanner so tests can cover terminal-text
  /// extraction without touching the user's Application Support folder.
  ///
  /// Signal-vs-noise: `input` and `hookEvent` are high-signal — the user
  /// typed a ticket id, or the agent emitted it as a notification. Any
  /// match there is kept. `outputTurn.delta` is the noisiest source — a
  /// single `git log --grep='CEN-'` dump or a grep across the codebase
  /// can drop dozens of incidental ids on screen, and `TranscriptDelta`'s
  /// scrollback-trim fallback re-emits whole buffers, so chips keep
  /// accumulating over a long session. Require **≥ 2 distinct outputTurns**
  /// for an output-only reference: a real focus comes back in conversation;
  /// a one-shot in a tool dump does not.
  static func scanTranscriptEntries(
    _ entries: [TranscriptEntry],
    allowedPrefixes: Set<String> = []
  ) -> [SessionReference] {
    var firstSeen: [String: SessionReference] = [:]
    var order: [String] = []
    var highSignalKeys = Set<String>()
    var outputTurnCounts: [String: Int] = [:]

    func recordFirstSeen(_ ref: SessionReference) {
      if firstSeen[ref.dedupeKey] == nil {
        firstSeen[ref.dedupeKey] = ref
        order.append(ref.dedupeKey)
      }
    }

    func observeHighSignal(_ text: String) {
      for ref in scanText(text, allowedPrefixes: allowedPrefixes) {
        recordFirstSeen(ref)
        highSignalKeys.insert(ref.dedupeKey)
      }
    }

    func observeOutputTurn(_ text: String) {
      var seenInTurn = Set<String>()
      for ref in scanText(text, allowedPrefixes: allowedPrefixes) {
        recordFirstSeen(ref)
        if seenInTurn.insert(ref.dedupeKey).inserted {
          outputTurnCounts[ref.dedupeKey, default: 0] += 1
        }
      }
    }

    for entry in entries {
      switch entry {
      case .input(let text, _):
        observeHighSignal(text)
      case .outputTurn(_, let delta, _):
        observeOutputTurn(delta)
      case .hookEvent(_, _, let title, let body, _, _, _, _):
        if let title { observeHighSignal(title) }
        if let body { observeHighSignal(body) }
      default:
        continue
      }
    }

    return order.compactMap { key in
      guard let ref = firstSeen[key] else { return nil }
      if highSignalKeys.contains(key) { return ref }
      if (outputTurnCounts[key] ?? 0) >= 2 { return ref }
      return nil
    }
  }

  /// Single-pass regex extraction from plain text. `allowedPrefixes` scopes
  /// ticket matches to a repo's Linear team keys (sourced from
  /// `RepositorySettings.linearTeamKeys`); an empty set matches any uppercase
  /// prefix.
  static func scanText(_ text: String, allowedPrefixes: Set<String> = []) -> [SessionReference] {
    guard !text.isEmpty else { return [] }
    var seen = Set<String>()
    var results: [SessionReference] = []

    // Regex literals (Swift regex builder syntax). `\b` word boundaries
    // prevent matches being picked up inside longer identifiers.
    // Scoped to the function so Swift 6 doesn't complain about static
    // Regex values (Regex isn't Sendable).
    let ticketRegex = /\b([A-Z][A-Z0-9]{1,9}-\d+)\b/
    let prURLRegex = /https:\/\/github\.com\/([\w.-]+)\/([\w.-]+)\/pull\/(\d+)/

    for match in text.matches(of: ticketRegex) {
      let id = String(match.output.1)
      if !allowedPrefixes.isEmpty {
        // Extract prefix (before the `-`) and check allowlist.
        let prefix = id.split(separator: "-").first.map(String.init) ?? ""
        guard allowedPrefixes.contains(prefix) else { continue }
      }
      let ref = SessionReference.ticket(id: id)
      if seen.insert(ref.dedupeKey).inserted {
        results.append(ref)
      }
    }

    for match in text.matches(of: prURLRegex) {
      let owner = String(match.output.1)
      let repo = String(match.output.2)
      guard let number = Int(match.output.3) else { continue }
      let ref = SessionReference.pullRequest(
        owner: owner, repo: repo, number: number, state: nil, title: nil
      )
      if seen.insert(ref.dedupeKey).inserted {
        results.append(ref)
      }
    }

    return results
  }

}
