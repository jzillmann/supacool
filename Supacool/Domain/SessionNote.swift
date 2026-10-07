import Foundation

/// A piece of terminal output the user pinned from a session ("Pin
/// Selection" in the terminal's right-click menu).
///
/// The text is the durable part: it survives relaunch, Resume and Rerun.
/// The jump back into scrollback is best-effort — it searches the live
/// terminal for `searchNeedle`, so it works while the PTY that printed the
/// text is still alive and the line has not scrolled out of the scrollback
/// cap. A row number would be cheaper but breaks on scrollback trimming,
/// on resize reflow, and when Claude Code redraws its transcript.
nonisolated struct SessionNote: Identifiable, Hashable, Codable, Sendable {
  let id: UUID
  var text: String
  /// The `SessionTerminal.id` the text was pinned from (a tab terminal's
  /// id is its tab id; an adopted pane's id is its surface id).
  let terminalID: UUID
  /// The Ghostty surface the selection was on. The jump focuses it so the
  /// search runs in the right split pane.
  let surfaceID: UUID
  let createdAt: Date

  init(
    id: UUID = UUID(),
    text: String,
    terminalID: UUID,
    surfaceID: UUID,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.text = text
    self.terminalID = terminalID
    self.surfaceID = surfaceID
    self.createdAt = createdAt
  }

  enum CodingKeys: String, CodingKey {
    case id, text, terminalID, surfaceID, createdAt
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
    terminalID = try c.decodeIfPresent(UUID.self, forKey: .terminalID) ?? UUID()
    surfaceID = try c.decodeIfPresent(UUID.self, forKey: .surfaceID) ?? terminalID
    createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(text, forKey: .text)
    try c.encode(terminalID, forKey: .terminalID)
    try c.encode(surfaceID, forKey: .surfaceID)
    try c.encode(createdAt, forKey: .createdAt)
  }

  /// Pinned text is capped so a select-all of a huge scrollback cannot
  /// bloat the session file.
  static let maxTextLength = 20_000

  /// Ghostty's matcher is a literal substring search over rendered cells,
  /// and a needle longer than the terminal is wide never matches across the
  /// soft wrap. 60 characters fits any usable pane width.
  static let searchNeedleCap = 60

  /// Shorter lines ("1.", "---", "}") match all over the scrollback.
  static let minimumDistinctiveLineLength = 16

  /// One line of the pinned text, used as the scrollback search needle:
  /// the first line long enough to be distinctive, else the longest line.
  /// Nil when the text has no searchable characters.
  var searchNeedle: String? {
    let lines = text.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    guard
      let line = lines.first(where: { $0.count >= Self.minimumDistinctiveLineLength })
        ?? lines.max(by: { $0.count < $1.count })
    else { return nil }
    return String(line.prefix(Self.searchNeedleCap))
  }

  /// First non-empty line, for list rows and the chip tooltip.
  var title: String {
    text.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .first(where: { !$0.isEmpty }) ?? ""
  }

  /// Normalizes raw selection text into what gets stored: trailing
  /// whitespace stripped from every line (terminal rows are padded),
  /// blank lead/tail lines dropped, capped at `maxTextLength`. Nil when
  /// nothing remains.
  static func normalized(_ raw: String) -> String? {
    let lines = raw.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
      .map { line -> String in
        var line = Substring(line)
        while let last = line.last, last.isWhitespace { line = line.dropLast() }
        return String(line)
      }
    guard
      let first = lines.firstIndex(where: { !$0.isEmpty }),
      let last = lines.lastIndex(where: { !$0.isEmpty })
    else { return nil }
    let joined = lines[first...last].joined(separator: "\n")
    return String(joined.prefix(maxTextLength))
  }
}
