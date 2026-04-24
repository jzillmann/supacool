import SwiftUI

/// Single pill-shaped bookmark card. Tap to spawn; right-click for edit /
/// delete. Styling mirrors `SessionCardView` (subtle glass background,
/// rounded continuous corners) in a compact size.
struct BookmarkPillView: View {
  let bookmark: Bookmark
  let onTap: () -> Void
  let onEdit: () -> Void
  let onDelete: () -> Void

  var body: some View {
    Button(action: onTap) {
      HStack(spacing: 6) {
        Image(systemName: agentIcon)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(agentColor)
        Text(bookmark.name)
          .font(.caption)
          .monospaced()
          .lineLimit(1)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .background(.background.secondary, in: pillShape)
      .overlay(
        pillShape.strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5)
      )
      .contentShape(pillShape)
    }
    .buttonStyle(.plain)
    .help(helpText)
    .contextMenu {
      Button("Edit…", systemImage: "pencil", action: onEdit)
      Divider()
      Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
    }
  }

  private var pillShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: 8, style: .continuous)
  }

  private var agentIcon: String {
    switch bookmark.agent {
    case .claude: "brain"
    case .codex: "terminal.fill"
    case .none: "apple.terminal"
    }
  }

  private var agentColor: Color {
    switch bookmark.agent {
    case .claude: .purple
    case .codex: .cyan
    case .none: .secondary
    }
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
