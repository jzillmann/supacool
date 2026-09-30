import ComposableArchitecture
import SwiftUI

/// One chip per tag (`SessionGroup`) above the board. Clicking a chip filters
/// the board to that tag's members; clicking it again (or "All") clears the
/// filter. Shelving tags show a shelf glyph — their members are hidden from
/// the unfiltered board and only appear while their chip is selected.
///
/// Tags are created from a card's context menu ("New Tag…") or by dragging
/// one card onto another; a chip's context menu toggles the shelf behavior
/// and deletes the tag.
struct TagFilterBar: View {
  @Bindable var store: StoreOf<BoardFeature>

  var body: some View {
    let liveIDs = Set(store.sessions.map(\.id))
    ScrollView(.horizontal) {
      HStack(spacing: 6) {
        chip(
          title: "All",
          systemImage: nil,
          count: nil,
          isSelected: store.tagFilterID == nil,
          help: "Show every session except shelved ones"
        ) {
          store.send(.tagFilterSelected(nil))
        }
        ForEach(store.sessionGroups) { tag in
          chip(
            title: tag.name,
            systemImage: tag.shelves ? "archivebox" : "tag",
            count: tag.sessionIDs.filter(liveIDs.contains).count,
            isSelected: store.tagFilterID == tag.id,
            help: tag.shelves
              ? "Open the \(tag.name) shelf (its sessions are hidden from the board otherwise)"
              : "Show only sessions tagged \(tag.name)"
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

  private func chip(
    title: String,
    systemImage: String?,
    count: Int?,
    isSelected: Bool,
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
    .help(help)
  }
}
