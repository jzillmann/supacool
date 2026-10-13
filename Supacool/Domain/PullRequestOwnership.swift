import Foundation

/// Per-session evidence about which pull requests this session *owns* rather
/// than merely mentions. Keyed by `SessionReference.dedupeKey`
/// (`pr:owner/repo#42`).
///
/// A PR reference is any PR URL that shows up in a transcript, so one PR
/// routinely lands on several cards: the session that opened it, a session
/// the user pasted the link into, a review session. Only one of them should
/// work on it — a second session pushing to the same PR is almost always an
/// accident. `PullRequestOwnership` resolves the single owner from these marks;
/// everything else holding the PR is a watcher.
nonisolated struct PullRequestOwnershipMarks: Codable, Hashable, Sendable {
  /// PRs this session opened itself — the transcript scanner saw a
  /// `gh pr create` (or a create-pull-request tool call) whose result printed
  /// the PR URL. The strongest automatic signal.
  var created: Set<String>
  /// Explicit "Make This Session the Owner" picks. The newest claim across
  /// the board wins, so moving ownership never needs to touch other sessions.
  var claimedAt: [String: Date]
  /// When the PR first appeared in this session's references. The earliest
  /// session to see a PR is usually the one whose `gh pr create` printed it.
  /// Missing for references that predate this field — `createdAt` stands in.
  var firstSeenAt: [String: Date]
  /// PRs the user confirmed this session only watches. Silences the
  /// shared-PR warning on this card; the PR stays a watched (non-owned) one.
  var acknowledgedWatching: Set<String>

  init(
    created: Set<String> = [],
    claimedAt: [String: Date] = [:],
    firstSeenAt: [String: Date] = [:],
    acknowledgedWatching: Set<String> = []
  ) {
    self.created = created
    self.claimedAt = claimedAt
    self.firstSeenAt = firstSeenAt
    self.acknowledgedWatching = acknowledgedWatching
  }

  // MARK: - Codable (forward-compatible per docs/agent-guides/persistence.md)

  enum CodingKeys: String, CodingKey {
    case created, claimedAt, firstSeenAt, acknowledgedWatching
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    created = try c.decodeIfPresent(Set<String>.self, forKey: .created) ?? []
    claimedAt = try c.decodeIfPresent([String: Date].self, forKey: .claimedAt) ?? [:]
    firstSeenAt = try c.decodeIfPresent([String: Date].self, forKey: .firstSeenAt) ?? [:]
    acknowledgedWatching = try c.decodeIfPresent(Set<String>.self, forKey: .acknowledgedWatching) ?? []
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(created, forKey: .created)
    try c.encode(claimedAt, forKey: .claimedAt)
    try c.encode(firstSeenAt, forKey: .firstSeenAt)
    try c.encode(acknowledgedWatching, forKey: .acknowledgedWatching)
  }
}

/// Why a session is the owner of a PR, strongest first.
nonisolated enum PullRequestOwnerReason: Equatable, Sendable {
  /// The user picked this session ("Make This Session the Owner").
  case claimed
  /// This session opened the PR (`gh pr create`).
  case created
  /// No stronger signal: this session saw the PR first.
  case firstSeen
}

/// A session as the ownership UI names it.
nonisolated struct PullRequestSessionLabel: Equatable, Hashable, Sendable {
  let id: AgentSession.ID
  let name: String
}

/// One session's relation to one PR it references.
nonisolated enum PullRequestRole: Equatable, Sendable {
  /// This session owns the PR. `sharedWith` lists the watchers, oldest first;
  /// empty when no other session holds the PR.
  case owner(reason: PullRequestOwnerReason, sharedWith: [PullRequestSessionLabel])
  /// Another session owns the PR. `acknowledged` is true once the user
  /// confirmed this session only watches it. `isSettled` is true for a merged
  /// or closed PR — history, so nothing to warn about.
  case watcher(owner: PullRequestSessionLabel, acknowledged: Bool, isSettled: Bool)

  var isWatcher: Bool {
    if case .watcher = self { return true }
    return false
  }

  /// True when this card should warn: it holds a live PR another session owns
  /// and the user has not said that is fine.
  var needsAttention: Bool {
    if case .watcher(_, let acknowledged, let isSettled) = self {
      return !acknowledged && !isSettled
    }
    return false
  }

  /// Tooltip line that says who owns the PR and who else holds it.
  var helpText: String {
    switch self {
    case .owner(let reason, let sharedWith):
      let origin =
        switch reason {
        case .claimed: "Owned by this session (picked by you)"
        case .created: "Owned by this session (it opened the PR)"
        case .firstSeen: "Owned by this session"
        }
      guard !sharedWith.isEmpty else { return origin }
      return "\(origin) · also in: \(sharedWith.map(\.name).joined(separator: ", "))"
    case .watcher(let owner, let acknowledged, let isSettled):
      if isSettled || acknowledged {
        return "Owned by “\(owner.name)” — this session only watches it"
      }
      return "⚠ Owned by “\(owner.name)” — only the owner should work on this PR"
    }
  }
}

/// Resolves the single owner of each pull request across board sessions.
///
/// Ranking, per PR: the newest manual claim, else the session that created
/// the PR (earliest first-seen if several claim creation), else the session
/// that saw it first. Ties break on `createdAt`, then on the id, so the owner
/// never flips between renders.
///
/// Pure and cheap: lookups only walk the sessions for the PR keys the caller
/// asks about, so a card with no PR references costs nothing.
nonisolated enum PullRequestOwnership {
  /// The owning session's id for `refKey`, or nil when no session holds it.
  static func ownerID(of refKey: String, in sessions: [AgentSession]) -> AgentSession.ID? {
    rankedHolders(of: refKey, in: sessions).first?.session.id
  }

  /// The owning session for `refKey`, or nil when no session holds it.
  static func owner(of refKey: String, in sessions: [AgentSession]) -> AgentSession? {
    rankedHolders(of: refKey, in: sessions).first?.session
  }

  /// Every session holding `refKey`, owner first.
  static func holders(of refKey: String, in sessions: [AgentSession]) -> [AgentSession] {
    rankedHolders(of: refKey, in: sessions).map(\.session)
  }

  /// `session`'s role for each PR it references, keyed by dedupe key.
  static func roles(
    for session: AgentSession,
    in sessions: [AgentSession]
  ) -> [String: PullRequestRole] {
    var roles: [String: PullRequestRole] = [:]
    for reference in session.references where reference.isPullRequestReference {
      let key = reference.dedupeKey
      let ranked = rankedHolders(of: key, in: sessions)
      guard let owner = ranked.first else { continue }
      if owner.session.id == session.id {
        let watchers = ranked.dropFirst()
          .sorted { lhs, rhs in
            lhs.seenAt != rhs.seenAt ? lhs.seenAt < rhs.seenAt : lhs.session.createdAt < rhs.session.createdAt
          }
          .map { label(for: $0.session) }
        roles[key] = .owner(reason: owner.reason, sharedWith: watchers)
      } else {
        roles[key] = .watcher(
          owner: label(for: owner.session),
          acknowledged: session.pullRequestOwnership.acknowledgedWatching.contains(key),
          isSettled: isSettled(key, in: ranked.map(\.session))
        )
      }
    }
    return roles
  }

  /// PR keys `session` references but does not own. Ball-court logic skips
  /// these: a watcher must not be parked, resurfaced, or auto-resumed by a PR
  /// another session is driving.
  static func watchedKeys(of session: AgentSession, in sessions: [AgentSession]) -> Set<String> {
    var keys = Set<String>()
    for reference in session.references where reference.isPullRequestReference {
      let key = reference.dedupeKey
      if let ownerID = ownerID(of: key, in: sessions), ownerID != session.id {
        keys.insert(key)
      }
    }
    return keys
  }

  // MARK: - Ranking

  private struct Holder {
    let session: AgentSession
    let reason: PullRequestOwnerReason
    let claimedAt: Date?
    let seenAt: Date
  }

  private static func rankedHolders(of refKey: String, in sessions: [AgentSession]) -> [Holder] {
    let target = PullRequestKey(refKey)
    let holders = sessions.compactMap { session -> Holder? in
      guard session.references.contains(where: { target.matches($0) }) else { return nil }
      let marks = session.pullRequestOwnership
      let claimedAt = marks.claimedAt[refKey]
      let reason: PullRequestOwnerReason =
        claimedAt != nil ? .claimed : (marks.created.contains(refKey) ? .created : .firstSeen)
      return Holder(
        session: session,
        reason: reason,
        claimedAt: claimedAt,
        seenAt: marks.firstSeenAt[refKey] ?? session.createdAt
      )
    }
    return holders.sorted(by: outranks)
  }

  private static func outranks(_ lhs: Holder, _ rhs: Holder) -> Bool {
    let lhsRank = rank(lhs.reason)
    let rhsRank = rank(rhs.reason)
    if lhsRank != rhsRank { return lhsRank < rhsRank }
    if let lhsClaim = lhs.claimedAt, let rhsClaim = rhs.claimedAt, lhsClaim != rhsClaim {
      return lhsClaim > rhsClaim
    }
    if lhs.seenAt != rhs.seenAt { return lhs.seenAt < rhs.seenAt }
    if lhs.session.createdAt != rhs.session.createdAt {
      return lhs.session.createdAt < rhs.session.createdAt
    }
    return lhs.session.id.uuidString < rhs.session.id.uuidString
  }

  private static func rank(_ reason: PullRequestOwnerReason) -> Int {
    switch reason {
    case .claimed: 0
    case .created: 1
    case .firstSeen: 2
    }
  }

  /// A merged or closed PR is history: any holder's cached state says so.
  private static func isSettled(_ refKey: String, in sessions: [AgentSession]) -> Bool {
    let target = PullRequestKey(refKey)
    for session in sessions {
      for reference in session.references where target.matches(reference) {
        if case .pullRequest(_, _, _, let state, _) = reference, state == .merged || state == .closed {
          return true
        }
      }
    }
    return false
  }

  private static func label(for session: AgentSession) -> PullRequestSessionLabel {
    PullRequestSessionLabel(id: session.id, name: session.displayName)
  }

  /// A PR dedupe key matched against references field by field. The board
  /// classifies every card on each render and each lookup walks every
  /// session's references, so building `dedupeKey` strings there would
  /// allocate per reference per card. Falls back to string comparison for a
  /// key that doesn't parse.
  private struct PullRequestKey {
    let raw: String
    let number: Int?

    init(_ raw: String) {
      self.raw = raw
      self.number = raw.split(separator: "#").last.flatMap { Int($0) }
    }

    func matches(_ reference: SessionReference) -> Bool {
      guard case .pullRequest(_, _, let refNumber, _, _) = reference else { return false }
      if let number, number != refNumber { return false }
      return reference.dedupeKey == raw
    }
  }
}
