import SwiftUI

/// Single pill-shaped bookmark card. Tap to spawn; right-click for edit /
/// delete. Styling mirrors `SessionCardView` (subtle glass background,
/// rounded continuous corners) in a compact size.
struct BookmarkPillView: View {
  let bookmark: Bookmark
  let onTap: () -> Void
  let onEdit: () -> Void
  let onDelete: () -> Void

  @State private var isHovered: Bool = false

  var body: some View {
    Button(action: onTap) {
      HStack(spacing: 6) {
        AgentIconView(agent: bookmark.agent, size: 11, weight: .medium)
        Text(bookmark.name)
          .font(.caption)
          .monospaced()
          .lineLimit(1)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .background(.background.secondary, in: pillShape)
      .overlay(
        pillShape.strokeBorder(
          Color.secondary.opacity(isHovered ? 0.5 : 0.2),
          lineWidth: isHovered ? 1 : 0.5
        )
      )
      .contentShape(pillShape)
    }
    .buttonStyle(.plain)
    .help(helpText)
    .animation(.easeOut(duration: 0.12), value: isHovered)
    .onHover { hovering in
      isHovered = hovering
      if hovering {
        NSCursor.pointingHand.push()
      } else {
        NSCursor.pop()
      }
    }
    .contextMenu {
      Button("Edit…", systemImage: "pencil", action: onEdit)
      Divider()
      Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
    }
  }

  private var pillShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: 8, style: .continuous)
  }

  private var helpText: String {
    let worktreeNote: String
    switch bookmark.worktreeMode {
    case .newWorktree: worktreeNote = "new worktree"
    case .repoRoot: worktreeNote = "repo root"
    }
    return "\(bookmark.prompt.prefix(120))\n(\(AgentType.displayName(for: bookmark.agent)) · \(worktreeNote))"
  }
}
