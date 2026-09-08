import Foundation

/// Ghostty `link` rules Supacool injects on top of the user's ghostty config,
/// plus the click-side mapping from a matched string back to the URL we open.
///
/// Ghostty matches links by regex and, on click, hands the matched *text* to
/// the system opener. That is fine for a URL and useless for a bare ticket id
/// (`open CEN-9398` goes nowhere), so the two halves live here together:
/// `configLines` builds the matcher, `linearURL(forMatched:)` resolves the
/// click. `GhosttySurfaceBridge` claims the open action for anything this type
/// recognizes and lets everything else fall through to ghostty.
///
/// The `link` option is not settable in stock ghostty — see
/// `patches/ghostty-link-config.patch`.
nonisolated enum TerminalLinkRules {
  /// Ticket ids are only matched for explicitly configured Linear team keys.
  /// An unscoped `[A-Z]+-\d+` matcher would light up `UTF-8`, `RFC-1918` and
  /// `ISO-8601`, and clicking one would open a nonexistent Linear issue.
  static func ticketRegex(teamKeys: Set<String>) -> String? {
    let keys = sanitizedTeamKeys(teamKeys)
    guard !keys.isEmpty else { return nil }
    return #"\b("# + keys.joined(separator: "|") + #")-\d+\b"#
  }

  /// Lines appended to Supacool's bundled ghostty config. Empty when there is
  /// nothing to match, so we never install a dead matcher.
  ///
  /// The highlight mirrors ghostty's built-in URL link (hover while holding
  /// ⌘) so a ticket id behaves exactly like a URL in the same terminal.
  static func configLines(teamKeys: Set<String>) -> String {
    guard let regex = ticketRegex(teamKeys: teamKeys) else { return "" }
    return "link = \(regex),open,hover-mods:super\n"
  }

  /// Resolve text ghostty matched back to the URL we actually want to open.
  /// Returns `nil` for anything that is not one of our ticket matches — the
  /// caller must then leave the action to ghostty.
  static func linearURL(
    forMatched matched: String,
    teamKeys: Set<String>,
    linearOrgSlug: String
  ) -> URL? {
    let trimmed = matched.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let id = ticketID(in: trimmed, teamKeys: teamKeys) else { return nil }
    return SessionReference.ticket(id: id).url(linearOrgSlug: linearOrgSlug)
  }

  /// The ticket id if `text` is exactly one, and its prefix is a configured
  /// team key. Anchored: ghostty hands us the whole match, and we refuse to
  /// guess at a ticket buried inside a longer string.
  static func ticketID(in text: String, teamKeys: Set<String>) -> String? {
    let ticketRegex = /^([A-Z][A-Z0-9]{1,9})-(\d+)$/
    guard let match = text.wholeMatch(of: ticketRegex) else { return nil }
    let prefix = String(match.output.1)
    guard sanitizedTeamKeys(teamKeys).contains(prefix) else { return nil }
    return "\(prefix)-\(match.output.2)"
  }

  /// Uppercased, deduplicated, sorted (so the generated config is stable
  /// across launches) and filtered to what is safe to drop into a regex
  /// alternation verbatim.
  static func sanitizedTeamKeys(_ teamKeys: Set<String>) -> [String] {
    Set(
      teamKeys
        .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
        .filter { key in
          !key.isEmpty && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        }
    )
    .sorted()
  }
}
