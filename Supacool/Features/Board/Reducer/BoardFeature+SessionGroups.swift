import ComposableArchitecture
import Foundation

/// Session-group ("pin sessions together") reducer handlers, extracted from
/// the main `BoardFeature` switch so the huge `body` stays inside the Swift
/// type-checker's budget (same rationale as `BoardFeature+SessionLifecycle`).
///
/// Groups are durable: only permanent session removal purges a member (see
/// `removeSessionFromState`); detaching/rerunning keeps it. See
/// `SessionGroup` for the model.
extension BoardFeature {
  func reducePinSessionToNewGroup(
    state: inout State,
    id: AgentSession.ID,
    name: String
  ) -> Effect<Action> {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let fallback = state.sessions.first(where: { $0.id == id })?.displayName ?? "Group"
    let resolvedName = trimmed.isEmpty ? fallback : trimmed
    let group = SessionGroup(
      id: uuid(),
      name: resolvedName,
      sessionIDs: [id],
      createdAt: date.now
    )
    state.$sessionGroups.withLock { $0.append(group) }
    return .none
  }

  func reduceAddSessionToGroup(
    state: inout State,
    id: AgentSession.ID,
    groupID: SessionGroup.ID
  ) -> Effect<Action> {
    state.$sessionGroups.withLock { groups in
      guard let index = groups.firstIndex(where: { $0.id == groupID }),
        !groups[index].sessionIDs.contains(id)
      else { return }
      groups[index].sessionIDs.append(id)
    }
    return .none
  }

  func reduceRemoveSessionFromGroup(
    state: inout State,
    id: AgentSession.ID,
    groupID: SessionGroup.ID
  ) -> Effect<Action> {
    state.$sessionGroups.withLock { groups in
      guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
      groups[index].sessionIDs.removeAll { $0 == id }
      if groups[index].isEmpty {
        groups.remove(at: index)
      }
    }
    return .none
  }

  func reduceRenameGroup(
    state: inout State,
    id: SessionGroup.ID,
    name: String
  ) -> Effect<Action> {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .none }
    state.$sessionGroups.withLock { groups in
      guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
      groups[index].name = trimmed
    }
    return .none
  }

  func reduceCycleGroup(
    state: inout State,
    from: AgentSession.ID,
    direction: GroupCycleDirection
  ) -> Effect<Action> {
    // A session may live in several groups; cycling uses the first, which
    // is stable pin order.
    guard let group = state.sessionGroups.first(where: { $0.contains(from) }) else {
      return .none
    }
    let target: AgentSession.ID?
    switch direction {
    case .forward: target = group.memberAfter(from)
    case .backward: target = group.memberBefore(from)
    }
    guard let target else { return .none }
    return .send(.focusForward(to: target))
  }

  /// Drag-to-group. Precedence when the dragged card lands on a target:
  /// 1. target already in a group → add dragged to it,
  /// 2. else dragged already in a group → add target to it,
  /// 3. else form a fresh group from the pair (target first — it's the anchor
  ///    the user dropped onto), named after the target session.
  /// Dropping a card on itself, or on a card already in the same group, is a
  /// no-op.
  func reduceDropSessionOntoSession(
    state: inout State,
    dragged: AgentSession.ID,
    target: AgentSession.ID
  ) -> Effect<Action> {
    guard dragged != target else { return .none }

    if let targetGroupID = state.sessionGroups.first(where: { $0.contains(target) })?.id {
      return reduceAddSessionToGroup(state: &state, id: dragged, groupID: targetGroupID)
    }
    if let draggedGroupID = state.sessionGroups.first(where: { $0.contains(dragged) })?.id {
      return reduceAddSessionToGroup(state: &state, id: target, groupID: draggedGroupID)
    }

    let fallback = state.sessions.first(where: { $0.id == target })?.displayName ?? "Group"
    let group = SessionGroup(
      id: uuid(),
      name: fallback,
      sessionIDs: [target, dragged],
      createdAt: date.now
    )
    state.$sessionGroups.withLock { $0.append(group) }
    return .none
  }
}
