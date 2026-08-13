import ComposableArchitecture
import SwiftUI

/// Toolbar button + popover for **session groups** ("pins"). Lists every
/// group and its members; clicking a member jumps straight to that session's
/// full-screen terminal (the "quick open"). Groups are created from a card's
/// context menu ("Pin to New Group…"); this panel manages and navigates them.
///
/// Mirrors `RepoPickerButton` / `PRPulseButton`: a plain toolbar `Button` that
/// owns its own popover and takes the board store directly.
struct SessionGroupsButton: View {
  @Bindable var store: StoreOf<BoardFeature>
  @State private var isPresented: Bool = false

  var body: some View {
    Button {
      isPresented.toggle()
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "pin.fill")
          .foregroundStyle(.orange)
          .accessibilityHidden(true)
        Text("\(store.sessionGroups.count)")
          .font(.callout.monospacedDigit())
        Image(systemName: "chevron.down")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
      }
    }
    .help("Session groups — flip between pinned, related terminals (⌘⌥. to cycle)")
    .popover(isPresented: $isPresented, arrowEdge: .bottom) {
      SessionGroupsPanel(store: store, isPresented: $isPresented)
    }
  }
}

/// The popover body: one section per group, each with an inline-editable name,
/// a delete control, and its member rows.
private struct SessionGroupsPanel: View {
  @Bindable var store: StoreOf<BoardFeature>
  @Binding var isPresented: Bool
  /// Group currently under a card being dragged over the panel — drives the
  /// drop highlight.
  @State private var dropTargetedGroupID: SessionGroup.ID?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Groups")
        .font(.headline)
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 6)

      if store.sessionGroups.isEmpty {
        Text("No groups yet. Right-click a card → “Pin to New Group…”.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 14)
          .padding(.bottom, 12)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            ForEach(store.sessionGroups) { group in
              groupSection(group)
            }
          }
          .padding(.horizontal, 14)
          .padding(.bottom, 12)
        }
        .frame(maxHeight: 420)
      }
    }
    .frame(width: 300)
  }

  private func groupSection(_ group: SessionGroup) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Image(systemName: "pin.fill")
          .font(.caption)
          .foregroundStyle(.orange)
          .accessibilityHidden(true)
        // Inline rename: commit on submit; blank names are ignored by the
        // reducer, so an accidental clear can't wipe the label.
        TextField(
          "Group name",
          text: Binding(
            get: { group.name },
            set: { store.send(.renameGroup(id: group.id, name: $0)) }
          )
        )
        .textFieldStyle(.plain)
        .font(.subheadline.weight(.semibold))
        Spacer()
        Button {
          store.send(.deleteGroup(id: group.id))
        } label: {
          Image(systemName: "trash")
            .font(.caption)
            .accessibilityLabel("Delete group \(group.name)")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Delete this group (the sessions themselves are untouched)")
      }

      ForEach(group.sessionIDs, id: \.self) { sessionID in
        memberRow(sessionID: sessionID, group: group)
      }
    }
    .padding(6)
    .background(
      RoundedRectangle(cornerRadius: 6)
        .fill(dropTargetedGroupID == group.id ? Color.accentColor.opacity(0.15) : Color.clear)
    )
    // Drag a board card onto a group to add it.
    .dropDestination(for: String.self) { items, _ in
      guard let raw = items.first, let draggedID = UUID(uuidString: raw) else { return false }
      store.send(.addSessionToGroup(id: draggedID, groupID: group.id))
      return true
    } isTargeted: { targeted in
      if targeted {
        dropTargetedGroupID = group.id
      } else if dropTargetedGroupID == group.id {
        dropTargetedGroupID = nil
      }
    }
  }

  @ViewBuilder
  private func memberRow(sessionID: AgentSession.ID, group: SessionGroup) -> some View {
    let session = store.sessions.first(where: { $0.id == sessionID })
    HStack(spacing: 6) {
      Button {
        guard session != nil else { return }
        store.send(.focusForward(to: sessionID))
        isPresented = false
      } label: {
        HStack(spacing: 6) {
          Image(systemName: session == nil ? "questionmark.circle" : "terminal")
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
          Text(session?.displayName ?? "Unavailable")
            .font(.callout)
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(session == nil ? .secondary : .primary)
          Spacer()
        }
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .disabled(session == nil)

      Button {
        store.send(.removeSessionFromGroup(id: sessionID, groupID: group.id))
      } label: {
        Image(systemName: "pin.slash")
          .font(.caption2)
          .accessibilityLabel("Remove from group")
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .help("Remove from group")
    }
    .padding(.leading, 18)
  }
}
