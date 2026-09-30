import SwiftUI

/// One-line stand-in for a `SessionCardView` in dormant piles (Parked). A
/// parked card has no live terminal, so the full card's live chips (PR
/// status, vitals, review loop) carry nothing worth their render cost — and
/// a pile can hold dozens of them. The row keeps what triage needs (status,
/// title, repo, tags, last activity) and the context-menu verbs a parked card
/// offers: rename, priority, unpark, resume, snooze, tags, remove.
struct CompactSessionRow: View {
  let session: AgentSession
  let repositoryName: String?
  let status: BoardSessionStatus
  /// Every tag, so the menu can toggle membership; the row shows the ones
  /// that contain this session.
  let allTags: [SessionGroup]
  let isHighlighted: Bool
  let isSelected: Bool
  let onTap: () -> Void
  let onRename: () -> Void
  let onTogglePriority: () -> Void
  let onUnpark: (() -> Void)?
  let onResumePicker: (() -> Void)?
  let onSnooze: ((SnoozeOption) -> Void)?
  let onToggleTag: (SessionGroup.ID) -> Void
  let onNewTag: (String) -> Void
  let onRemove: () -> Void

  @State private var isHovered: Bool = false
  @State private var isNewTagPromptShown: Bool = false
  @State private var newTagName: String = ""

  var body: some View {
    Button(action: onTap) {
      HStack(spacing: 8) {
        Image(systemName: status.systemImage)
          .font(.caption)
          .foregroundStyle(status.color)
          .accessibilityLabel(status.label)
        AgentIconView(agent: session.agent, size: 12)
          .help(AgentType.displayName(for: session.agent))
        if session.isPriority {
          Image(systemName: "flag.fill")
            .font(.caption2)
            .foregroundStyle(.orange)
            .accessibilityLabel("Priority")
        }
        Text(session.displayName)
          .font(.callout)
          .lineLimit(1)
          .truncationMode(.tail)
          .foregroundStyle(.primary)
        if let repositoryName {
          Text(repositoryName)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        ForEach(allTags.filter { $0.contains(session.id) }) { tag in
          HStack(spacing: 2) {
            Image(systemName: tag.shelves ? "archivebox" : "tag")
              .accessibilityHidden(true)
            Text(tag.name)
              .lineLimit(1)
          }
          .font(.caption2)
          .foregroundStyle(.secondary)
        }
        Spacer(minLength: 8)
        Text(session.lastActivityAt, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .monospacedDigit()
          .lineLimit(1)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(rowFill)
      )
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .help("Open \(session.displayName)")
    .onHover { isHovered = $0 }
    .contextMenu { menu }
    .alert("New tag", isPresented: $isNewTagPromptShown) {
      TextField("Tag name", text: $newTagName)
      Button("Cancel", role: .cancel) {}
      Button("Create") { onNewTag(newTagName) }
    } message: {
      Text("Tag this session. Filter the board by tag, flip between tagged sessions with ⌘⌥. , or shelve a tag.")
    }
  }

  private var rowFill: AnyShapeStyle {
    if isSelected { return AnyShapeStyle(.tint.opacity(0.18)) }
    return isHighlighted || isHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear)
  }

  /// Flat sections, never nested `Menu`s — the live-refreshing board
  /// collapses submenus mid-hover (see `SessionCardView`'s Set Status note).
  @ViewBuilder
  private var menu: some View {
    Button("Rename…", systemImage: "pencil", action: onRename)
    Button(
      session.isPriority ? "Remove Priority" : "Mark as Priority",
      systemImage: session.isPriority ? "flag.slash" : "flag.fill",
      action: onTogglePriority
    )
    Divider()
    if let onUnpark {
      Button("Unpark", systemImage: "play.circle", action: onUnpark)
    }
    if let onResumePicker {
      Button("Resume via Picker…", systemImage: "play.circle", action: onResumePicker)
    }
    if let onSnooze {
      Section("Snooze Until") {
        ForEach(SnoozeOption.allCases) { option in
          Button(option.label, systemImage: option.systemImage) { onSnooze(option) }
        }
      }
    }
    Divider()
    ForEach(allTags) { tag in
      Button {
        onToggleTag(tag.id)
      } label: {
        Label(tag.name, systemImage: tag.contains(session.id) ? "tag.fill" : "tag")
      }
    }
    Button("New Tag…", systemImage: "tag.badge.plus") {
      newTagName = ""
      isNewTagPromptShown = true
    }
    Divider()
    Button("Remove", systemImage: "trash", role: .destructive, action: onRemove)
  }
}
