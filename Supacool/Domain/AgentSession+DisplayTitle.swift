import Foundation

extension AgentSession {
  /// `displayName` for surfaces that already render the primary ticket chip
  /// beside the title. Linear-armed sessions used to be named
  /// `"CEN-9156 · Capability templates"`, so the id showed up twice in a row.
  nonisolated var titleBesideTicketChip: String {
    // Only the first ticket *reference* renders as the chip — not
    // `primaryTicketID`, which also falls back to the launch prompt.
    let chipTicketID = references.lazy.compactMap { reference -> String? in
      if case .ticket(let id) = reference { return id }
      return nil
    }.first
    return Self.title(displayName, strippingTicketPrefix: chipTicketID)
  }

  /// Drops a leading `ticketID` (case-insensitive) plus the separator after it
  /// (`·`, `:`, `-`, `–`, `—`, `|`, whitespace). Leaves the title alone when
  /// the id isn't a prefix, isn't followed by a separator (so `CEN-91560`
  /// survives `CEN-9156`), or nothing would remain.
  nonisolated static func title(_ title: String, strippingTicketPrefix ticketID: String?) -> String {
    guard let ticketID, !ticketID.isEmpty else { return title }
    let trimmed = title.trimmingCharacters(in: .whitespaces)
    guard trimmed.count > ticketID.count,
      trimmed.prefix(ticketID.count).caseInsensitiveCompare(ticketID) == .orderedSame
    else { return title }
    let separators: Set<Character> = ["·", ":", "-", "–", "—", "|", " ", "\t"]
    let rest = trimmed.dropFirst(ticketID.count)
    guard let first = rest.first, separators.contains(first) else { return title }
    let remainder = rest.drop(while: { separators.contains($0) })
    return remainder.isEmpty ? title : String(remainder)
  }
}
