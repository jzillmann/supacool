import SwiftUI

/// A single draft pill rendered in the slim drafts strip above the board's
/// Bookmarks row. Visually distinct from `BookmarkPillView` (dashed
/// border + ghosted background) to telegraph "this is unfinished work,
/// not a saved template." Tap → reopens the New Terminal sheet pre-filled.
/// Right-click → Delete.
struct DraftPillView: View {
  let draft: Draft
  /// Optional short repo label ("supacool", "ghostty"…). Nil when the
  /// draft has no repo selected (or the repo was unregistered after the
  /// draft was saved). Rendered as a trailing dimmed suffix when present.
  let repoLabel: String?
  let onTap: () -> Void
  let onDelete: () -> Void

  @State private var isHovered: Bool = false

  var body: some View {
    Button(action: onTap) {
      HStack(spacing: 6) {
        AgentIconView(agent: draft.agent, size: 11, weight: .medium)
        Text(draft.displayLabel)
          .font(.caption)
          .lineLimit(1)
          .truncationMode(.tail)
        if let repoLabel {
          Text(repoLabel)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .frame(maxWidth: 220, alignment: .leading)
      .background(.background.tertiary, in: pillShape)
      .overlay(
        pillShape.strokeBorder(
          Color.secondary.opacity(isHovered ? 0.5 : 0.28),
          style: StrokeStyle(lineWidth: 0.75, dash: [3, 3])
        )
      )
      .contentShape(pillShape)
    }
    .buttonStyle(.plain)
    .help(helpText)
    .animation(.easeOut(duration: 0.12), value: isHovered)
    .onHover { isHovered = $0 }
    .contextMenu {
      Button("Delete Draft", systemImage: "trash", role: .destructive, action: onDelete)
    }
  }

  private var pillShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: 8, style: .continuous)
  }

  private var helpText: String {
    let preview = draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let body = preview.isEmpty ? "(empty prompt)" : String(preview.prefix(180))
    let agent = AgentType.displayName(for: draft.agent)
    let repo = repoLabel.map { " · \($0)" } ?? ""
    return "\(body)\n(\(agent)\(repo))"
  }
}
