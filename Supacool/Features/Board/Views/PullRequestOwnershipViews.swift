import ComposableArchitecture
import SwiftUI

/// What PR chips need to show and change PR ownership: this session's role per
/// PR (see `PullRequestOwnership`) plus the verbs. The default value has no
/// roles, which hides every ownership affordance — previews and surfaces that
/// don't wire ownership render exactly as before.
struct PullRequestOwnershipChipContext {
  var roles: [String: PullRequestRole] = [:]
  /// "Make This Session the Owner" — takes the PR's dedupe key.
  var onClaim: ((String) -> Void)?
  /// "Keep as Watcher" — takes the PR's dedupe key.
  var onAcknowledgeWatching: ((String) -> Void)?
  /// Jump to another session holding the PR (its owner or a watcher).
  var onOpenSession: ((AgentSession.ID) -> Void)?

  func role(for reference: SessionReference) -> PullRequestRole? {
    roles[reference.dedupeKey]
  }

  /// PRs this session holds but another session owns. Ball-court triage skips
  /// them so the card never gets a reason pill for someone else's PR.
  var watchedKeys: Set<String> {
    Set(roles.filter { $0.value.isWatcher }.keys)
  }

  /// True when any of `references` warrants the shared-PR warning.
  func needsAttention(_ references: [SessionReference]) -> Bool {
    references.contains { role(for: $0)?.needsAttention == true }
  }

  /// `session`'s roles resolved across every board session (not only the
  /// visible ones — the owner may be filtered out), wired to the board verbs.
  @MainActor
  static func board(_ store: StoreOf<BoardFeature>, session: AgentSession) -> Self {
    let id = session.id
    return Self(
      roles: PullRequestOwnershipIndex.board(store.sessions).roles(for: session),
      onClaim: { key in store.send(.claimPullRequest(id: id, dedupeKey: key)) },
      onAcknowledgeWatching: { key in store.send(.acknowledgePullRequestWatching(id: id, dedupeKey: key)) },
      onOpenSession: { target in store.send(.focusSession(id: target)) }
    )
  }
}

/// The leading chip glyph for a PR another session owns: a yellow warning
/// while the overlap is unconfirmed, a quiet eye once the user said this
/// session only watches (or the PR is settled). Nothing for an owned PR.
struct PullRequestOwnershipGlyph: View {
  let role: PullRequestRole?

  var body: some View {
    if let role, role.isWatcher {
      Image(systemName: role.needsAttention ? "exclamationmark.triangle.fill" : "eye")
        .font(.caption2)
        .foregroundStyle(role.needsAttention ? AnyShapeStyle(.yellow) : AnyShapeStyle(.secondary))
        .accessibilityLabel(role.needsAttention ? "Owned by another session" : "Watching")
    }
  }
}

/// Context-menu items for a PR chip or popover row: jump to the owner, take
/// ownership, or confirm this session only watches. `afterAction` lets a
/// popover close itself.
struct PullRequestOwnershipMenuItems: View {
  let reference: SessionReference
  let context: PullRequestOwnershipChipContext
  var afterAction: () -> Void = {}

  var body: some View {
    switch context.role(for: reference) {
    case .watcher(let owner, _, _)?:
      Divider()
      if let onOpenSession = context.onOpenSession {
        Button {
          onOpenSession(owner.id)
          afterAction()
        } label: {
          Label("Open Owner “\(owner.name)”", systemImage: "arrow.right.circle")
        }
      }
      if let onClaim = context.onClaim {
        Button {
          onClaim(reference.dedupeKey)
          afterAction()
        } label: {
          Label("Make This Session the Owner", systemImage: "person.crop.circle.badge.checkmark")
        }
      }
      if context.role(for: reference)?.needsAttention == true,
        let onAcknowledge = context.onAcknowledgeWatching
      {
        Button {
          onAcknowledge(reference.dedupeKey)
          afterAction()
        } label: {
          Label("Keep as Watcher", systemImage: "eye")
        }
      }
    case .owner(_, let sharedWith)? where !sharedWith.isEmpty:
      if let onOpenSession = context.onOpenSession {
        Divider()
        Menu {
          ForEach(sharedWith, id: \.id) { watcher in
            Button(watcher.name) {
              onOpenSession(watcher.id)
              afterAction()
            }
          }
        } label: {
          let noun = sharedWith.count == 1 ? "Session" : "Sessions"
          Label("Also in \(sharedWith.count) Other \(noun)", systemImage: "person.2")
        }
      }
    default:
      EmptyView()
    }
  }
}
