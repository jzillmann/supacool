import ComposableArchitecture
import SwiftUI

/// Floating bar of short-lived notification cards anchored bottom-trailing
/// over the Matrix Board. Cards represent transient signals (hook drift,
/// session spawn in flight, …) — not persistent UI. Each card supports a
/// primary tap (call-to-action) and × dismiss. The view is a zero-size
/// passthrough when `store.trayCards` is empty so callers can always install
/// it as an overlay without worrying about layout cost.
struct BoardTrayView: View {
  @Bindable var store: StoreOf<BoardFeature>

  var body: some View {
    if !store.trayCards.isEmpty {
      HStack(alignment: .bottom, spacing: 10) {
        ForEach(store.trayCards) { card in
          TrayCardView(
            card: card,
            onPrimary: { store.send(.trayCardPrimaryTapped(id: card.id)) },
            onDismiss: { store.send(.trayCardDismissed(id: card.id)) }
          )
          .transition(
            .asymmetric(
              insertion: .move(edge: .bottom).combined(with: .opacity),
              removal: .opacity
            )
          )
        }
      }
      .padding(.trailing, 16)
      .padding(.bottom, 16)
      .animation(.spring(response: 0.35, dampingFraction: 0.85), value: store.trayCards)
    }
  }
}

private struct TrayCardView: View {
  let card: TrayCard
  let onPrimary: () -> Void
  let onDismiss: () -> Void

  @State private var isHovering: Bool = false

  var body: some View {
    Button(action: onPrimary) {
      content
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.primary.opacity(isHovering ? 0.14 : 0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .help(presentation.helpText)
  }

  private var content: some View {
    HStack(alignment: .top, spacing: 10) {
      leadingIndicator

      VStack(alignment: .leading, spacing: 2) {
        Text(presentation.title)
          .font(.callout.weight(.medium))
          .foregroundStyle(.primary)
        if let subtitle = presentation.subtitle {
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      }
      .multilineTextAlignment(.leading)
      .frame(maxWidth: 220, alignment: .leading)

      Button(action: onDismiss) {
        Image(systemName: "xmark")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.secondary)
          .padding(4)
          .contentShape(Rectangle())
          .accessibilityLabel("Dismiss")
      }
      .buttonStyle(.plain)
      .opacity(isHovering ? 1 : 0.6)
      .help("Dismiss")
    }
  }

  @ViewBuilder
  private var leadingIndicator: some View {
    switch card.kind {
    case .sessionCreating:
      // Spinner in place of an icon so the card reads as "in progress"
      // at a glance — matches the "creation takes a while" framing.
      ProgressView()
        .controlSize(.small)
        .frame(width: 18, alignment: .center)
        .accessibilityHidden(true)
    default:
      Image(systemName: presentation.icon)
        .font(.callout)
        .foregroundStyle(presentation.tint)
        .frame(width: 18, alignment: .center)
        .accessibilityHidden(true)
    }
  }

  private var presentation: TrayCardPresentation {
    switch card.kind {
    case .staleHooks(let slots):
      return TrayCardPresentation(
        icon: "exclamationmark.triangle.fill",
        tint: .orange,
        title: "Hooks out of date",
        subtitle: slots.isEmpty
          ? "Reinstall coding-agent hooks."
          : "Reinstall \(Self.describe(slots)) in Settings → Coding Agents.",
        helpText: "Open Settings → Coding Agents to reinstall the latest hook payload."
      )
    case .sessionCreating(_, let displayName):
      return TrayCardPresentation(
        icon: "terminal.fill",  // unused — leadingIndicator shows a spinner
        tint: Color.secondary,
        title: "Starting session",
        subtitle: displayName,
        helpText: "Open this session"
      )
    }
  }

  private static func describe(_ slots: [AgentHookSlot]) -> String {
    let labels = slots.map { slot -> String in
      switch slot {
      case .claudeProgress: "Claude Progress"
      case .claudeNotifications: "Claude Notifications"
      case .codexProgress: "Codex Progress"
      case .codexNotifications: "Codex Notifications"
      }
    }
    switch labels.count {
    case 0: return "hooks"
    case 1: return labels[0]
    case 2: return "\(labels[0]) and \(labels[1])"
    default:
      let head = labels.dropLast().joined(separator: ", ")
      return "\(head), and \(labels.last ?? "")"
    }
  }
}

private struct TrayCardPresentation {
  let icon: String
  let tint: Color
  let title: String
  let subtitle: String?
  let helpText: String
}
