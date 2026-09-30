import Foundation

/// Direction for cycle-to-next-in-group navigation (⌘⌥. / ⌘⌥⇧.).
nonisolated enum GroupCycleDirection: Equatable, Sendable {
  case forward
  case backward
}

/// A **tag**: a named set of agent sessions. The UI says "tag"; the type keeps
/// its historical name `SessionGroup` (and its `session-groups.json` file) so
/// existing groups carry over as tags without a migration.
///
/// Tags are orthogonal to the board's status lanes: a card keeps its live
/// status (Waiting on Me / External / In Progress) and can carry any number
/// of tags. Every tag is a quick filter, and ⌘⌥. / ⌘⌥⇧. flip between its
/// members (e.g. a "feature + its test runner" pair). A tag can also carry a
/// *behavior* — see `shelves`.
///
/// A group is **durable**: it survives a member session ending, detaching, or
/// being rerun. A dead member stays in the group (greyed in the UI, offering
/// the board's existing Resume/Rerun) and re-binds when brought back — the
/// group models related *tasks*, not related live processes.
///
/// Membership is a plain ordered `[AgentSession.ID]` (`UUID`). Order is the
/// user's pin order and drives the ⌘⌥. / ⌘⌥⇧. "cycle to next/previous in
/// group" navigation. Groups are global (not per-repo) — a group can span
/// repos, since related work often does.
///
/// Persistence: forward-compatible Codable per `docs/agent-guides/persistence.md`.
/// Every field except the identity `id` decodes via `decodeIfPresent ?? default`.
nonisolated struct SessionGroup: Identifiable, Equatable, Hashable, Codable, Sendable {
  let id: UUID
  var name: String
  /// Ordered session membership. `AgentSession.ID` is `UUID`. May reference
  /// sessions that are currently dead/detached — see the type doc; the group
  /// deliberately keeps them.
  var sessionIDs: [UUID]
  let createdAt: Date
  /// Shelf behavior: members leave the live lanes (and ⌘. navigation) and
  /// collect behind one pill per tag — for work worth keeping but not
  /// pursuing now, like spikes. Any active tag filter lifts every shelf: the
  /// filtered tag's members show in their normal lanes, whatever else they
  /// carry — a filter is an explicit "show me these".
  var shelves: Bool
  /// Review cadence in days (`nil` = never asks). A tag whose last review is
  /// older than this is "review due": its chip and shelf pill say so until
  /// the user marks it reviewed — the weekly "anything parked that matters
  /// now?" pass, without a calendar reminder.
  var reviewIntervalDays: Int?
  /// When the user last marked this tag reviewed. `nil` counts from
  /// `createdAt`.
  var lastReviewedAt: Date?

  init(
    id: UUID = UUID(),
    name: String,
    sessionIDs: [UUID] = [],
    createdAt: Date = Date(),
    shelves: Bool = false,
    reviewIntervalDays: Int? = nil,
    lastReviewedAt: Date? = nil
  ) {
    self.id = id
    self.name = name
    self.sessionIDs = sessionIDs
    self.createdAt = createdAt
    self.shelves = shelves
    self.reviewIntervalDays = reviewIntervalDays
    self.lastReviewedAt = lastReviewedAt
  }

  // MARK: - Membership helpers

  var isEmpty: Bool { sessionIDs.isEmpty }

  func contains(_ sessionID: UUID) -> Bool { sessionIDs.contains(sessionID) }

  /// Whether the review cadence has run out. Counts calendar time, so a tag
  /// reviewed Monday 09:00 with a 7-day cadence is due again next Monday 09:00.
  func isReviewDue(now: Date) -> Bool {
    guard let reviewIntervalDays, reviewIntervalDays > 0 else { return false }
    let since = lastReviewedAt ?? createdAt
    guard let dueAt = Calendar.current.date(byAdding: .day, value: reviewIntervalDays, to: since) else {
      return false
    }
    return now >= dueAt
  }

  /// Ids of sessions that carry at least one shelving tag.
  static func shelvedSessionIDs(in groups: [SessionGroup]) -> Set<UUID> {
    var ids: Set<UUID> = []
    for group in groups where group.shelves {
      ids.formUnion(group.sessionIDs)
    }
    return ids
  }

  /// The member after `sessionID` in pin order, wrapping around. `nil` when
  /// the session isn't a member or the group has fewer than two members
  /// (nothing to switch to). Drives ⌘⌥. .
  func memberAfter(_ sessionID: UUID) -> UUID? {
    memberOffset(from: sessionID, by: 1)
  }

  /// The member before `sessionID` in pin order, wrapping around. Drives ⌘⌥⇧. .
  func memberBefore(_ sessionID: UUID) -> UUID? {
    memberOffset(from: sessionID, by: -1)
  }

  private func memberOffset(from sessionID: UUID, by step: Int) -> UUID? {
    guard sessionIDs.count > 1,
      let index = sessionIDs.firstIndex(of: sessionID)
    else { return nil }
    let next = (index + step + sessionIDs.count) % sessionIDs.count
    return sessionIDs[next]
  }

  /// Removes `sessionID` from every group's membership and drops any group
  /// that becomes empty. Called on *permanent* session removal — a merely
  /// detached/rerun session is deliberately kept (see the type doc).
  static func purging(sessionID: UUID, from groups: [SessionGroup]) -> [SessionGroup] {
    groups.compactMap { group in
      guard group.contains(sessionID) else { return group }
      var updated = group
      updated.sessionIDs.removeAll { $0 == sessionID }
      return updated.isEmpty ? nil : updated
    }
  }

  // MARK: - Codable (forward-compatible)

  enum CodingKeys: String, CodingKey {
    case id, name, sessionIDs, createdAt, shelves, reviewIntervalDays, lastReviewedAt
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(UUID.self, forKey: .id)
    name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
    sessionIDs = try c.decodeIfPresent([UUID].self, forKey: .sessionIDs) ?? []
    createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    shelves = try c.decodeIfPresent(Bool.self, forKey: .shelves) ?? false
    reviewIntervalDays = try c.decodeIfPresent(Int.self, forKey: .reviewIntervalDays)
    lastReviewedAt = try c.decodeIfPresent(Date.self, forKey: .lastReviewedAt)
  }
}
