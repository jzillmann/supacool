import Foundation

/// External work-item references parsed from a session's conversation.
/// Surfaced as chips on the board card so the user can jump from session
/// to Linear ticket / GitHub PR in one click.
nonisolated enum SessionReference: Codable, Equatable, Hashable, Sendable {
  /// Linear-style ticket id, e.g. `CEN-1234`. The prefix is the Linear
  /// team key. URL is computed at display time from the configured org
  /// slug (not stored — the slug can change without needing a rescan).
  case ticket(id: String)
  /// GitHub pull request, parsed from a full URL like
  /// `https://github.com/foo/bar/pull/42`. `state` is fetched lazily via
  /// `gh pr view` and cached on the session; nil means "not yet resolved".
  case pullRequest(owner: String, repo: String, number: Int, state: PRState?)

  // MARK: - Codable (forward-compatible per docs/agent-guides/persistence.md)

  enum DiscriminantKeys: String, CodingKey { case kind }
  enum TicketKeys: String, CodingKey { case id }
  enum PRKeys: String, CodingKey { case owner, repo, number, state }

  init(from decoder: Decoder) throws {
    let d = try decoder.container(keyedBy: DiscriminantKeys.self)
    let kind = try d.decode(String.self, forKey: .kind)
    switch kind {
    case "ticket":
      let c = try decoder.container(keyedBy: TicketKeys.self)
      let id = try c.decode(String.self, forKey: .id)
      self = .ticket(id: id)
    case "pullRequest":
      let c = try decoder.container(keyedBy: PRKeys.self)
      let owner = try c.decode(String.self, forKey: .owner)
      let repo = try c.decode(String.self, forKey: .repo)
      let number = try c.decode(Int.self, forKey: .number)
      let state = try c.decodeIfPresent(PRState.self, forKey: .state)
      self = .pullRequest(owner: owner, repo: repo, number: number, state: state)
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .kind,
        in: d,
        debugDescription: "Unknown SessionReference kind: \(kind)"
      )
    }
  }

  func encode(to encoder: Encoder) throws {
    switch self {
    case .ticket(let id):
      var d = encoder.container(keyedBy: DiscriminantKeys.self)
      try d.encode("ticket", forKey: .kind)
      var c = encoder.container(keyedBy: TicketKeys.self)
      try c.encode(id, forKey: .id)
    case .pullRequest(let owner, let repo, let number, let state):
      var d = encoder.container(keyedBy: DiscriminantKeys.self)
      try d.encode("pullRequest", forKey: .kind)
      var c = encoder.container(keyedBy: PRKeys.self)
      try c.encode(owner, forKey: .owner)
      try c.encode(repo, forKey: .repo)
      try c.encode(number, forKey: .number)
      try c.encodeIfPresent(state, forKey: .state)
    }
  }

  // MARK: - Stable keys for dedup / UI diffing

  /// Canonical string used to dedupe references across messages.
  /// E.g. `ticket:CEN-1234` or `pr:foo/bar#42`.
  var dedupeKey: String {
    switch self {
    case .ticket(let id): return "ticket:\(id)"
    case .pullRequest(let owner, let repo, let number, _):
      return "pr:\(owner)/\(repo)#\(number)"
    }
  }

  /// Short chip label for the board card.
  var chipLabel: String {
    switch self {
    case .ticket(let id): return id
    case .pullRequest(_, _, let number, _): return "#\(number)"
    }
  }

  /// Build the external URL for a ticket (nil if no Linear org configured).
  func url(linearOrgSlug: String) -> URL? {
    switch self {
    case .ticket(let id):
      let slug = linearOrgSlug.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !slug.isEmpty else { return nil }
      return URL(string: "https://linear.app/\(slug)/issue/\(id)")
    case .pullRequest(let owner, let repo, let number, _):
      return URL(string: "https://github.com/\(owner)/\(repo)/pull/\(number)")
    }
  }
}

/// GitHub PR state, simplified to the four we care about visually.
nonisolated enum PRState: String, Codable, Sendable {
  case open
  case merged
  case closed
  case draft

  /// System symbol shown in the chip.
  var systemImage: String {
    switch self {
    case .open: return "circle"
    case .merged: return "checkmark.circle.fill"
    case .closed: return "xmark.circle.fill"
    case .draft: return "pencil.circle"
    }
  }
}
