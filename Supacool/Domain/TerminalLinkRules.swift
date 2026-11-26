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
  static func configLines(teamKeys: Set<String>, repositorySlugs: [String] = []) -> String {
    var lines = ""
    if let regex = ticketRegex(teamKeys: teamKeys) {
      lines += "link = \(regex),open,hover-mods:super\n"
    }
    lines += "link = \(pullRequestRegex(repositorySlugs: repositorySlugs)),open,hover-mods:super\n"
    return lines
  }

  // MARK: - Pull requests

  /// Matches GitHub's short PR notation: `owner/repo#123` for any repo, and a
  /// bare `repo#123` for repos the board knows (so `README#1` or a markdown
  /// anchor never lights up). The lookbehind keeps `a/b#1` inside a longer
  /// path or URL from matching mid-way.
  static func pullRequestRegex(repositorySlugs: [String]) -> String {
    let names = Set(repositorySlugs.compactMap { slugParts($0)?.repo.lowercased() })
      .filter(isSafeName)
      .sorted()
      .map(regexEscaped)
    let shortForms = names.isEmpty ? "" : "|" + names.joined(separator: "|")
    return #"(?<![\w./-])(?:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+"# + shortForms + #")#\d+\b"#
  }

  /// Resolve a matched `owner/repo#123` or `repo#123` to its GitHub URL.
  /// A bare repo name must belong to exactly one known slug; nil otherwise,
  /// and the caller leaves the action to ghostty.
  static func pullRequestURL(forMatched matched: String, repositorySlugs: [String]) -> URL? {
    let trimmed = matched.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let reference = pullRequestReference(in: trimmed, repositorySlugs: repositorySlugs) else { return nil }
    return URL(string: "https://github.com/\(reference.owner)/\(reference.repo)/pull/\(reference.number)")
  }

  static func pullRequestReference(
    in text: String,
    repositorySlugs: [String]
  ) -> (owner: String, repo: String, number: Int)? {
    let pattern = /^(?:([A-Za-z0-9_.-]+)\/)?([A-Za-z0-9_.-]+)#(\d+)$/
    guard let match = text.wholeMatch(of: pattern), let number = Int(match.output.3) else { return nil }
    let repo = String(match.output.2)
    if let owner = match.output.1 {
      return (String(owner), repo, number)
    }
    let candidates = repositorySlugs.compactMap(slugParts).filter { $0.repo.lowercased() == repo.lowercased() }
    guard candidates.count == 1, let only = candidates.first else { return nil }
    return (only.owner, only.repo, number)
  }

  // MARK: - Colors

  /// Longest value we put on one `link-color` line. Ghostty reads config
  /// lines into a 4096-byte buffer and drops anything longer.
  static let maxColorRuleLength = 3500

  /// `link-color` lines tinting known tickets and PRs by state. `toneHex`
  /// resolves a tone to `#rrggbb` (the caller owns the palette, so it can
  /// follow light/dark mode). Rules are grouped per color, then per team or
  /// repo, so a busy board costs a handful of regex passes per frame rather
  /// than one per reference.
  static func colorConfigLines(
    catalog: TerminalReferenceCatalog,
    toneHex: (TerminalReferenceCatalog.Tone) -> String
  ) -> String {
    var lines: [String] = []

    // Tickets: color -> team key -> numbers.
    var ticketGroups: [String: [String: [String]]] = [:]
    for ticket in catalog.tickets.values {
      guard let match = ticket.identifier.wholeMatch(of: /([A-Z][A-Z0-9]{0,9})-(\d+)/) else { continue }
      guard let hex = ticket.colorHex ?? ticket.fallbackTone.map(toneHex) else { continue }
      ticketGroups[hex, default: [:]][String(match.output.1), default: []].append(String(match.output.2))
    }
    for hex in ticketGroups.keys.sorted() {
      let alternatives = ticketGroups[hex, default: [:]].keys.sorted().map { team in
        "\(team)-" + numberAlternation(ticketGroups[hex, default: [:]][team, default: []])
      }
      for chunk in chunked(alternatives) {
        lines.append(#"link-color = \b(?:"# + chunk.joined(separator: "|") + #")\b,"# + hex)
      }
    }

    // PRs: tone -> owner/repo -> numbers.
    var prGroups: [TerminalReferenceCatalog.Tone: [String: [String]]] = [:]
    for pullRequest in catalog.pullRequests.values {
      guard let tone = pullRequest.tone,
        isSafeName(pullRequest.owner), isSafeName(pullRequest.repo)
      else { continue }
      let slug = "\(pullRequest.owner)/\(pullRequest.repo)"
      prGroups[tone, default: [:]][slug, default: []].append(String(pullRequest.number))
    }
    for tone in TerminalReferenceCatalog.Tone.allCases {
      guard let bySlug = prGroups[tone] else { continue }
      let alternatives = bySlug.keys.sorted().compactMap { slug -> String? in
        guard let parts = slugParts(slug) else { return nil }
        let owner = regexEscaped(parts.owner)
        let repo = regexEscaped(parts.repo)
        return #"(?:(?<![\w./-])(?:"# + owner + "/)?" + repo + "#|github\\.com/" + owner + "/" + repo
          + "/pull/)" + numberAlternation(bySlug[slug, default: []])
      }
      // Case-sensitive on purpose: `(?i)` made every surface spend about a
      // third of a config reload on Unicode case folding. A ref typed in a
      // different case than GitHub's stays uncolored, but is still a link.
      for chunk in chunked(alternatives) {
        lines.append(#"link-color = (?:"# + chunk.joined(separator: "|") + #")\b,"# + toneHex(tone))
      }
    }

    return lines.map { $0 + "\n" }.joined()
  }

  private static func numberAlternation(_ numbers: [String]) -> String {
    "(?:" + Set(numbers).sorted().joined(separator: "|") + ")"
  }

  /// Split alternatives into groups whose joined length fits one config line.
  /// A single oversized alternative is dropped rather than truncated.
  private static func chunked(_ alternatives: [String]) -> [[String]] {
    var chunks: [[String]] = []
    var current: [String] = []
    var length = 0
    for alternative in alternatives where alternative.count < maxColorRuleLength {
      if !current.isEmpty, length + alternative.count + 1 > maxColorRuleLength {
        chunks.append(current)
        current = []
        length = 0
      }
      current.append(alternative)
      length += alternative.count + 1
    }
    if !current.isEmpty { chunks.append(current) }
    return chunks
  }

  private static func slugParts(_ slug: String) -> (owner: String, repo: String)? {
    PRPulseReference.coordinates(slug: slug)
  }

  /// GitHub owner and repo names are `[A-Za-z0-9_.-]`; anything else never
  /// reaches a regex.
  private static func isSafeName(_ name: String) -> Bool {
    !name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_.-".contains($0)) }
  }

  private static func regexEscaped(_ name: String) -> String {
    name.replacing(".", with: "\\.")
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
