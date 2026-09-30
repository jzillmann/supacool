import ComposableArchitecture
import SwiftUI

/// One chip per tag (`SessionGroup`) above the board. Clicking a chip filters
/// the board to that tag's members; clicking it again (or "All") clears the
/// filter. Shelving tags show a shelf glyph — their members are hidden from
/// the unfiltered board and only appear while their chip is selected.
///
/// Tags are created from a card's context menu ("New Tag…") or by dragging
/// one card onto another; a chip's context menu toggles the shelf behavior,
/// sets a review cadence, marks the tag reviewed and deletes it. A tag whose
/// review is due carries an orange dot.
///
/// ⌘1–⌘9 toggle the first nine tags. Safe on the board: the full-screen
/// terminal (which owns ⌘1–⌘9 for its tab strip) replaces the board rather
/// than covering it, and Ghostty's own ⌘-digit bindings are unbound
/// (`AppShortcuts.reservedGhosttyUnbindArguments`). ⌘0 is taken by the
/// Window menu, so "All" has no digit — press the active tag's digit again.
/// The keys are live only while the board's window is key (see
/// `controlActiveState`), so a sheet's own ⌘-digits always win.
struct TagFilterBar: View {
  @Bindable var store: StoreOf<BoardFeature>
  /// `.key` only while the board's window is the key window. A sheet over
  /// the board (the New Terminal sheet binds ⌘1/⌘2 for its agent picker)
  /// takes key status, so the chips' ⌘-digits switch off instead of
  /// competing with the sheet's.
  @Environment(\.controlActiveState) private var controlActiveState

  var body: some View {
    let liveIDs = Set(store.sessions.map(\.id))
    let now = Date()
    ScrollView(.horizontal) {
      HStack(spacing: 6) {
        chip(
          title: "All",
          systemImage: nil,
          count: nil,
          isSelected: store.tagFilterID == nil,
          isReviewDue: false,
          shortcutDigit: nil,
          help: "Show every session except shelved ones"
        ) {
          store.send(.tagFilterSelected(nil))
        }
        ForEach(Array(store.sessionGroups.enumerated()), id: \.element.id) { index, tag in
          let digit = index < 9 && controlActiveState == .key ? index + 1 : nil
          chip(
            title: tag.name,
            systemImage: tag.shelves ? "archivebox" : "tag",
            count: tag.sessionIDs.filter(liveIDs.contains).count,
            isSelected: store.tagFilterID == tag.id,
            isReviewDue: tag.isReviewDue(now: now),
            shortcutDigit: digit,
            help: (tag.shelves
              ? "Open the \(tag.name) shelf (its sessions are hidden from the board otherwise)"
              : "Show only sessions tagged \(tag.name)")
              + (tag.isReviewDue(now: now) ? " — review due; right-click → Mark Reviewed when done" : "")
          ) {
            store.send(.tagFilterSelected(store.tagFilterID == tag.id ? nil : tag.id))
          }
          .contextMenu {
            Button(
              tag.shelves ? "Keep on Board" : "Shelve Members",
              systemImage: tag.shelves ? "rectangle.stack" : "archivebox"
            ) {
              store.send(.toggleTagShelves(id: tag.id))
            }
            Divider()
            // Flat items, never a nested `Menu`: the live-refreshing board
            // collapses submenus mid-hover (same reason as Snooze Until).
            if tag.reviewIntervalDays != nil {
              Button("Mark Reviewed", systemImage: "checkmark.circle") {
                store.send(.markTagReviewed(id: tag.id))
              }
            }
            ForEach(Self.reviewCadences, id: \.days) { cadence in
              Button {
                store.send(.setTagReviewInterval(id: tag.id, days: cadence.days))
              } label: {
                Label(
                  cadence.title,
                  systemImage: tag.reviewIntervalDays == cadence.days ? "checkmark" : "calendar"
                )
              }
            }
            Divider()
            Button("Delete Tag", systemImage: "trash", role: .destructive) {
              store.send(.deleteGroup(id: tag.id))
            }
          }
          // Drag a board card onto a chip to tag it.
          .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, let draggedID = UUID(uuidString: raw) else { return false }
            store.send(.addSessionToGroup(id: draggedID, groupID: tag.id))
            return true
          }
        }
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 8)
    }
    .scrollIndicators(.never)
  }

  private static let reviewCadences: [(title: String, days: Int?)] = [
    ("Review Weekly", 7),
    ("Review Every 2 Weeks", 14),
    ("No Review", nil),
  ]

  private func chip(
    title: String,
    systemImage: String?,
    count: Int?,
    isSelected: Bool,
    isReviewDue: Bool,
    shortcutDigit: Int?,
    help: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 4) {
        if let systemImage {
          Image(systemName: systemImage)
            .font(.caption)
            .accessibilityHidden(true)
        }
        Text(title)
          .font(.subheadline.weight(isSelected ? .semibold : .regular))
          .lineLimit(1)
        if let count {
          Text("\(count)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        if isReviewDue {
          Circle()
            .fill(.orange)
            .frame(width: 6, height: 6)
            .accessibilityLabel("Review due")
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 4)
      .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
      .background(
        Capsule(style: .continuous)
          .fill(isSelected ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.thinMaterial))
      )
      .overlay(
        Capsule(style: .continuous)
          .strokeBorder(isSelected ? AnyShapeStyle(.tint.opacity(0.5)) : AnyShapeStyle(.quaternary), lineWidth: 0.5)
      )
      .contentShape(.capsule)
    }
    .buttonStyle(.plain)
    .keyboardShortcut(shortcutDigit.map { KeyboardShortcut(KeyEquivalent(Character(String($0))), modifiers: .command) })
    .help(shortcutDigit.map { "\(help) (⌘\($0))" } ?? help)
  }
}
