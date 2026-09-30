import ComposableArchitecture
import SwiftUI

/// Toolbar button + popover for **tags** (`SessionGroup`). Lists every tag
/// and its members; clicking a member jumps straight to that session's
/// full-screen terminal (the "quick open"). Tags are created from a card's
/// context menu ("New Tag…"); this panel renames, shelves and deletes them.
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
        Image(systemName: "tag.fill")
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
    .help("Tags — jump between tagged sessions (⌘⌥. to cycle), rename, shelve or delete tags")
    .popover(isPresented: $isPresented, arrowEdge: .bottom) {
      SessionGroupsPanel(store: store, isPresented: $isPresented)
    }
  }
}

/// The popover body: one section per group, each with an inline-editable name,
/// a delete control, and its member rows.
private struct SessionGroupsPanel: View {
  /// Which slice of the group list the panel is showing. Defaults to
  /// `.current` so opening the panel while inside a pinned session lands on
  /// that session's group — the common case is "flip to a sibling", not
  /// "browse every group".
  private enum Scope: Hashable {
    case current
    case all
  }

  @Bindable var store: StoreOf<BoardFeature>
  @Binding var isPresented: Bool
  /// Group currently under a card being dragged over the panel — drives the
  /// drop highlight.
  @State private var dropTargetedGroupID: SessionGroup.ID?
  @State private var scope: Scope = .current

  /// The group owning the session the user currently has open, if any. A
  /// session can live in several groups; the first is stable pin order, which
  /// matches what ⌘⌥. cycles through.
  private var currentGroup: SessionGroup? {
    guard let focused = store.focusedSessionID else { return nil }
    return store.sessionGroups.first(where: { $0.contains(focused) })
  }

  private var displayedGroups: [SessionGroup] {
    guard scope == .current, let currentGroup else { return store.sessionGroups }
    return [currentGroup]
  }

  /// Only worth offering the switch when there's something to switch to.
  private var showsScopePicker: Bool {
    currentGroup != nil && store.sessionGroups.count > 1
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Text("Tags")
          .font(.headline)
        Spacer(minLength: 8)
        if showsScopePicker {
          Picker("Show", selection: $scope) {
            Text("This").tag(Scope.current)
            Text("All (\(store.sessionGroups.count))").tag(Scope.all)
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .fixedSize()
          .controlSize(.small)
          .help("Show only the tag of the session you have open, or every tag")
        }
      }
      .padding(.horizontal, 14)
      .padding(.top, 12)
      .padding(.bottom, 6)

      if store.sessionGroups.isEmpty {
        Text("No tags yet. Right-click a card → “New Tag…”.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 14)
          .padding(.bottom, 12)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            ForEach(displayedGroups) { group in
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
        Image(systemName: group.shelves ? "archivebox.fill" : "tag.fill")
          .font(.caption)
          .foregroundStyle(.orange)
          .accessibilityHidden(true)
        // Inline rename: commit on submit; blank names are ignored by the
        // reducer, so an accidental clear can't wipe the label.
        TextField(
          "Tag name",
          text: Binding(
            get: { group.name },
            set: { store.send(.renameGroup(id: group.id, name: $0)) }
          )
        )
        .textFieldStyle(.plain)
        .font(.subheadline.weight(.semibold))
        Spacer()
        Button {
          store.send(.toggleTagShelves(id: group.id))
        } label: {
          Image(systemName: group.shelves ? "archivebox.fill" : "archivebox")
            .font(.caption)
            .accessibilityLabel(group.shelves ? "Keep \(group.name) on the board" : "Shelve \(group.name)")
        }
        .buttonStyle(.plain)
        .foregroundStyle(group.shelves ? .orange : .secondary)
        .help(
          group.shelves
            ? "Shelved: members stay off the board until you pick this tag's filter. Click to keep them on the board."
            : "Shelve: hide this tag's sessions from the board behind one pill (for spikes and parked ideas)"
        )
        Button {
          store.send(.deleteGroup(id: group.id))
        } label: {
          Image(systemName: "trash")
            .font(.caption)
            .accessibilityLabel("Delete tag \(group.name)")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Delete this tag (the sessions themselves are untouched)")
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

  private func memberRow(sessionID: AgentSession.ID, group: SessionGroup) -> some View {
    SessionGroupMemberRow(
      session: store.sessions.first(where: { $0.id == sessionID }),
      isCurrent: store.focusedSessionID == sessionID,
      onOpen: {
        store.send(.focusForward(to: sessionID))
        isPresented = false
      },
      onRemove: {
        store.send(.removeSessionFromGroup(id: sessionID, groupID: group.id))
      }
    )
  }
}

/// One member of a tag in the panel. Marks the session the user is inside
/// right now (accent tint + filled icon) and lights up under the pointer, so
/// the list reads as clickable and "where am I" is answered at a glance.
private struct SessionGroupMemberRow: View {
  let session: AgentSession?
  let isCurrent: Bool
  let onOpen: () -> Void
  let onRemove: () -> Void
  @State private var isHovered = false

  private var rowFill: Color {
    if isCurrent { return Color.accentColor.opacity(isHovered ? 0.3 : 0.2) }
    if isHovered, session != nil { return Color.primary.opacity(0.08) }
    return .clear
  }

  var body: some View {
    HStack(spacing: 6) {
      Button {
        guard session != nil else { return }
        onOpen()
      } label: {
        HStack(spacing: 6) {
          Image(systemName: iconName)
            .font(.caption)
            .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
            .accessibilityHidden(true)
          Text(session?.displayName ?? "Unavailable")
            .font(isCurrent ? .callout.weight(.semibold) : .callout)
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(session == nil ? .secondary : .primary)
          Spacer()
        }
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .disabled(session == nil)
      .help(isCurrent ? "You are in this session" : "Open this session")
      .accessibilityAddTraits(isCurrent ? .isSelected : [])

      Button(action: onRemove) {
        Image(systemName: "tag.slash")
          .font(.caption2)
          .accessibilityLabel("Remove tag")
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .opacity(isHovered || isCurrent ? 1 : 0.5)
      .help("Remove this tag from the session")
    }
    .padding(.vertical, 3)
    .padding(.horizontal, 6)
    .background(RoundedRectangle(cornerRadius: 5).fill(rowFill))
    .padding(.leading, 12)
    .onHover { isHovered = $0 }
    .animation(.easeOut(duration: 0.12), value: isHovered)
  }

  private var iconName: String {
    guard session != nil else { return "questionmark.circle" }
    return isCurrent ? "terminal.fill" : "terminal"
  }
}
