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
/// These one-shot helpers build a `PullRequestOwnershipIndex` per call — fine
/// for reducers, which ask once per action. Views ask once per card per
/// render, so they go through `PullRequestOwnershipIndex.board(_:)` instead.
nonisolated enum PullRequestOwnership {
  /// The owning session's id for `refKey`, or nil when no session holds it.
  static func ownerID(of refKey: String, in sessions: [AgentSession]) -> AgentSession.ID? {
    PullRequestOwnershipIndex(sessions: sessions).ownerID(of: refKey)
  }

  /// The owning session for `refKey`, or nil when no session holds it.
  static func owner(of refKey: String, in sessions: [AgentSession]) -> AgentSession? {
    PullRequestOwnershipIndex(sessions: sessions).holders(of: refKey).first
  }

  /// Every session holding `refKey`, owner first.
  static func holders(of refKey: String, in sessions: [AgentSession]) -> [AgentSession] {
    PullRequestOwnershipIndex(sessions: sessions).holders(of: refKey)
  }

  /// `session`'s role for each PR it references, keyed by dedupe key.
  static func roles(
    for session: AgentSession,
    in sessions: [AgentSession]
  ) -> [String: PullRequestRole] {
    PullRequestOwnershipIndex(sessions: sessions).roles(for: session)
  }

  /// PR keys `session` references but does not own. Ball-court logic skips
  /// these: a watcher must not be parked, resurfaced, or auto-resumed by a PR
  /// another session is driving.
  static func watchedKeys(of session: AgentSession, in sessions: [AgentSession]) -> Set<String> {
    PullRequestOwnershipIndex(sessions: sessions).watchedKeys(of: session)
  }
}

/// Every PR's ranked holders, resolved in one pass over the sessions.
///
/// The board classifies each card on every render, and each card asks about
/// its own PRs. Ranking per question walked every session for every PR of
/// every card — quadratic in the board size, and with ~100 cards it kept the
/// main thread busy most of the time. The index walks the sessions once;
/// each question after that is a dictionary lookup.
nonisolated struct PullRequestOwnershipIndex: Sendable {
  /// Input sessions; `Holder.position` points into this array.
  let sessions: [AgentSession]
  private let holdersByKey: [String: [Holder]]
  /// PRs some holder's cached state reports merged or closed — history.
  private let settledKeys: Set<String>

  init(sessions: [AgentSession]) {
    var holdersByKey: [String: [Holder]] = [:]
    var settledKeys = Set<String>()
    for (position, session) in sessions.enumerated() {
      var seenKeys = Set<String>()
      for reference in session.references {
        guard case .pullRequest(_, _, _, let state, _) = reference else { continue }
        let key = reference.dedupeKey
        if state == .merged || state == .closed { settledKeys.insert(key) }
        guard seenKeys.insert(key).inserted else { continue }
        let marks = session.pullRequestOwnership
        let claimedAt = marks.claimedAt[key]
        let reason: PullRequestOwnerReason =
          claimedAt != nil ? .claimed : (marks.created.contains(key) ? .created : .firstSeen)
        holdersByKey[key, default: []].append(
          Holder(
            position: position,
            id: session.id,
            createdAt: session.createdAt,
            reason: reason,
            claimedAt: claimedAt,
            seenAt: marks.firstSeenAt[key] ?? session.createdAt
          )
        )
      }
    }
    self.sessions = sessions
    self.holdersByKey = holdersByKey.mapValues { $0.sorted(by: Self.outranks) }
    self.settledKeys = settledKeys
  }

  /// The owning session's id for `refKey`, or nil when no session holds it.
  func ownerID(of refKey: String) -> AgentSession.ID? {
    holdersByKey[refKey]?.first?.id
  }

  /// Every session holding `refKey`, owner first.
  func holders(of refKey: String) -> [AgentSession] {
    (holdersByKey[refKey] ?? []).map { sessions[$0.position] }
  }

  /// `session`'s role for each PR it references, keyed by dedupe key.
  func roles(for session: AgentSession) -> [String: PullRequestRole] {
    var roles: [String: PullRequestRole] = [:]
    for reference in session.references where reference.isPullRequestReference {
      let key = reference.dedupeKey
      guard let ranked = holdersByKey[key], let owner = ranked.first else { continue }
      if owner.id == session.id {
        let watchers = ranked.dropFirst()
          .sorted { lhs, rhs in
            lhs.seenAt != rhs.seenAt ? lhs.seenAt < rhs.seenAt : lhs.createdAt < rhs.createdAt
          }
          .map(label(for:))
        roles[key] = .owner(reason: owner.reason, sharedWith: watchers)
      } else {
        roles[key] = .watcher(
          owner: label(for: owner),
          acknowledged: session.pullRequestOwnership.acknowledgedWatching.contains(key),
          isSettled: settledKeys.contains(key)
        )
      }
    }
    return roles
  }

  /// PR keys `session` references but does not own.
  func watchedKeys(of session: AgentSession) -> Set<String> {
    var keys = Set<String>()
    for reference in session.references where reference.isPullRequestReference {
      let key = reference.dedupeKey
      if let ownerID = ownerID(of: key), ownerID != session.id {
        keys.insert(key)
      }
    }
    return keys
  }

  // MARK: - Ranking

  private struct Holder: Sendable {
    let position: Int
    let id: AgentSession.ID
    let createdAt: Date
    let reason: PullRequestOwnerReason
    let claimedAt: Date?
    let seenAt: Date
  }

  private func label(for holder: Holder) -> PullRequestSessionLabel {
    PullRequestSessionLabel(id: holder.id, name: sessions[holder.position].displayName)
  }

  private static func outranks(_ lhs: Holder, _ rhs: Holder) -> Bool {
    let lhsRank = rank(lhs.reason)
    let rhsRank = rank(rhs.reason)
    if lhsRank != rhsRank { return lhsRank < rhsRank }
    if let lhsClaim = lhs.claimedAt, let rhsClaim = rhs.claimedAt, lhsClaim != rhsClaim {
      return lhsClaim > rhsClaim
    }
    if lhs.seenAt != rhs.seenAt { return lhs.seenAt < rhs.seenAt }
    if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
    return lhs.id.uuidString < rhs.id.uuidString
  }

  private static func rank(_ reason: PullRequestOwnerReason) -> Int {
    switch reason {
    case .claimed: 0
    case .created: 1
    case .firstSeen: 2
    }
  }
}

extension PullRequestOwnershipIndex {
  @MainActor private static var boardCache: PullRequestOwnershipIndex?

  /// The index for the board's sessions, rebuilt only when they change.
  ///
  /// Every card's classification asks with the same `store.sessions` array.
  /// The cache keeps that array, and `==` on an array whose storage is
  /// shared returns at once without comparing elements, so an unchanged
  /// board costs one pointer check per question. Keeping the array also
  /// matters: while the cache holds it, a mutation must copy the storage,
  /// so a changed board can never pass as the cached one.
  @MainActor
  static func board(_ sessions: [AgentSession]) -> PullRequestOwnershipIndex {
    if let cached = boardCache, cached.sessions == sessions { return cached }
    let index = PullRequestOwnershipIndex(sessions: sessions)
    boardCache = index
    return index
  }
}
