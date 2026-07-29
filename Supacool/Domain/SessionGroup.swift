import Foundation

/// Direction for cycle-to-next-in-group navigation (⌘⌥. / ⌘⌥⇧.).
nonisolated enum GroupCycleDirection: Equatable, Sendable {
  case forward
  case backward
}

/// A named set of agent sessions the user has *pinned* together so they can
/// flip between related terminals without hunting the board (e.g. a "feature +
/// its test runner" pair, or a cluster of sessions all chasing one incident).
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

  init(
    id: UUID = UUID(),
    name: String,
    sessionIDs: [UUID] = [],
    createdAt: Date = Date()
  ) {
    self.id = id
    self.name = name
    self.sessionIDs = sessionIDs
    self.createdAt = createdAt
  }

  // MARK: - Membership helpers

  var isEmpty: Bool { sessionIDs.isEmpty }

  func contains(_ sessionID: UUID) -> Bool { sessionIDs.contains(sessionID) }

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
    case id, name, sessionIDs, createdAt
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(UUID.self, forKey: .id)
    name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
    sessionIDs = try c.decodeIfPresent([UUID].self, forKey: .sessionIDs) ?? []
    createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
  }
}
