import AppKit
import Sharing
import SwiftUI

/// Small status card pinned to a terminal pane's bottom-leading corner while
/// the mouse ⌘-hovers a ticket id or PR ref the board knows about. Ghostty
/// reports the hovered link text (`GhosttySurfaceState.mouseOverLink`); the
/// facts come from `@Shared(.terminalReferenceCatalog)`.
struct TerminalReferenceHoverCard: View {
  let state: GhosttySurfaceState
  @Shared(.terminalReferenceCatalog) private var catalog

  var body: some View {
    if let link = state.mouseOverLink, let entry = catalog.entry(forLinkText: link) {
      card(for: entry)
        .padding(8)
        .allowsHitTesting(false)
        .transition(.opacity)
    }
  }

  @ViewBuilder
  private func card(for entry: TerminalReferenceCatalog.Entry) -> some View {
    switch entry {
    case .ticket(let ticket):
      content(
        id: ticket.identifier,
        status: ticket.stateName ?? "Unknown state",
        color: ticketColor(ticket),
        title: ticket.title,
        detail: ticket.assigneeName.map { "Assignee: \($0)" } ?? "Unassigned"
      )
    case .pullRequest(let pullRequest):
      content(
        id: "\(pullRequest.repo)#\(pullRequest.number)",
        status: pullRequest.statusLabel,
        color: pullRequest.tone.map(Self.color(for:)) ?? .secondary,
        title: pullRequest.title,
        detail: pullRequest.detail
      )
    }
  }

  private func content(id: String, status: String, color: Color, title: String?, detail: String?) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 6) {
        Text(id)
          .font(.callout.monospaced().weight(.semibold))
        Circle()
          .fill(color)
          .frame(width: 7, height: 7)
        Text(status)
          .font(.callout)
          .foregroundStyle(color)
      }
      if let title, !title.isEmpty {
        Text(title)
          .font(.callout)
          .lineLimit(2)
      }
      if let detail, !detail.isEmpty {
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .frame(maxWidth: 420, alignment: .leading)
    .background(.regularMaterial, in: .rect(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8).strokeBorder(.separator)
    }
  }

  /// Linear's own state color, matching the tint in the terminal text.
  private func ticketColor(_ ticket: TerminalReferenceCatalog.Ticket) -> Color {
    if let hex = ticket.colorHex, let color = Self.color(hex: hex) { return color }
    return ticket.fallbackTone.map(Self.color(for:)) ?? .secondary
  }

  static func color(for tone: TerminalReferenceCatalog.Tone) -> Color {
    switch tone {
    case .green: .green
    case .yellow: .yellow
    case .orange: .orange
    case .red: .red
    case .purple: .purple
    case .blue: .blue
    case .gray: .gray
    }
  }

  private static func color(hex: String) -> Color? {
    guard let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
    return Color(
      .sRGB,
      red: Double((value >> 16) & 0xFF) / 255,
      green: Double((value >> 8) & 0xFF) / 255,
      blue: Double(value & 0xFF) / 255
    )
  }
}
