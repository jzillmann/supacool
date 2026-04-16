import ComposableArchitecture
import Foundation

/// Extracts ticket IDs (e.g. `CEN-1234`) and GitHub PR URLs from a Claude
/// Code session's native transcript file, so the board card can surface
/// them as clickable chips.
///
/// The transcript lives at `~/.claude/projects/<hashed>/<session-id>.jsonl`
/// where `<hashed>` is the session's CWD with `/` replaced by `-`. Codex
/// sessions don't have a Supacool-readable equivalent yet, so they fall
/// back to `scanText` on just the initial prompt.
struct SessionReferenceScannerClient: Sendable {
  /// Read the JSONL and pull out every unique ticket/PR reference from
  /// user and assistant messages. Returns `[]` if the file doesn't exist.
  var scan: @Sendable (_ cwdPath: String, _ agentNativeSessionID: String) async -> [SessionReference]
  /// One-shot regex pass over a plain string (e.g. `session.initialPrompt`).
  var scanText: @Sendable (_ text: String) -> [SessionReference]
}

extension SessionReferenceScannerClient: DependencyKey {
  static let liveValue = Self(
    scan: { cwdPath, agentNativeSessionID in
      SessionReferenceScannerLive.scan(
        cwdPath: cwdPath,
        agentNativeSessionID: agentNativeSessionID
      )
    },
    scanText: { text in
      SessionReferenceScannerLive.scanText(text)
    }
  )

  static let testValue = Self(
    scan: { _, _ in [] },
    scanText: { _ in [] }
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
  /// Claude Code's project-path hash: replace every `/` with `-`.
  /// E.g. `/Users/jz/Projects/foo` → `-Users-jz-Projects-foo`.
  static func hashProjectPath(_ path: String) -> String {
    path.replacingOccurrences(of: "/", with: "-")
  }

  /// Absolute path to the JSONL transcript file.
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

  static func scan(cwdPath: String, agentNativeSessionID: String) -> [SessionReference] {
    guard !agentNativeSessionID.isEmpty else { return [] }
    let url = jsonlURL(cwdPath: cwdPath, agentNativeSessionID: agentNativeSessionID)
    guard let data = try? Data(contentsOf: url) else {
      return []
    }
    guard let content = String(data: data, encoding: .utf8) else {
      scannerLogger.warning("JSONL was not UTF-8: \(url.path)")
      return []
    }
    return scanJSONL(content)
  }

  /// Parse a JSONL blob, extract message text, run reference regexes,
  /// dedupe by canonical key.
  static func scanJSONL(_ jsonl: String) -> [SessionReference] {
    var seen = Set<String>()
    var results: [SessionReference] = []
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
      let text = extractText(from: message["content"])
      for ref in scanText(text) {
        if seen.insert(ref.dedupeKey).inserted {
          results.append(ref)
        }
      }
    }
    return results
  }

  /// Message content is either a plain string (simple user turn) or an
  /// array of typed blocks. We recursively pull out `text` and `tool_result`
  /// content, skipping `thinking` (Claude's internal monologue) and
  /// `tool_use` (noisy tool invocations).
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

  /// Single-pass regex extraction from plain text. Applies the ticket
  /// prefix allowlist from UserDefaults (`supacool.references.ticketPrefixes`,
  /// comma-separated). Empty allowlist = match any uppercase prefix.
  static func scanText(_ text: String) -> [SessionReference] {
    guard !text.isEmpty else { return [] }
    var seen = Set<String>()
    var results: [SessionReference] = []

    let allowedPrefixes = loadTicketPrefixAllowlist()

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
        owner: owner, repo: repo, number: number, state: nil
      )
      if seen.insert(ref.dedupeKey).inserted {
        results.append(ref)
      }
    }

    return results
  }

  /// Reads `supacool.references.ticketPrefixes` from UserDefaults and
  /// returns a normalized Set of uppercase prefixes. Empty set = allow any.
  private static func loadTicketPrefixAllowlist() -> Set<String> {
    let raw = UserDefaults.standard.string(forKey: "supacool.references.ticketPrefixes") ?? ""
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    return Set(
      trimmed
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
        .filter { !$0.isEmpty }
    )
  }

}
