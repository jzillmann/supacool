import SwiftUI

/// One-line stand-in for a `SessionCardView` in dormant piles (Parked). A
/// parked card has no live terminal, so the full card's live chips (PR
/// status, vitals, review loop) carry nothing worth their render cost — and
/// a pile can hold dozens of them. The row keeps what triage needs: status,
/// title, repo, tags, last activity, and the park/remove verbs.
struct CompactSessionRow: View {
  let session: AgentSession
  let repositoryName: String?
  let status: BoardSessionStatus
  let tags: [SessionGroup]
  let isHighlighted: Bool
  let onTap: () -> Void
  let onUnpark: (() -> Void)?
  let onRemove: () -> Void

  @State private var isHovered: Bool = false

  var body: some View {
    Button(action: onTap) {
      HStack(spacing: 8) {
        Image(systemName: status.systemImage)
          .font(.caption)
          .foregroundStyle(status.color)
          .accessibilityLabel(status.label)
        AgentIconView(agent: session.agent, size: 12)
          .help(AgentType.displayName(for: session.agent))
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
        ForEach(tags) { tag in
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
          .fill(isHighlighted || isHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
      )
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .help("Open \(session.displayName)")
    .onHover { isHovered = $0 }
    .contextMenu {
      if let onUnpark {
        Button("Unpark", systemImage: "play.circle", action: onUnpark)
      }
      Button("Remove", systemImage: "trash", role: .destructive, action: onRemove)
    }
  }
}
