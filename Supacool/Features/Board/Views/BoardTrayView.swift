import ComposableArchitecture
import SwiftUI

/// Floating bar of transient cards anchored bottom-trailing over the board.
/// Cards bubble in from the bottom and slide out on dismiss. Each card body
/// is tappable (primary) and has an ✕ button (dismiss). The view is a
/// zero-size passthrough when both pushed cards and the New-Terminal draft
/// are empty, so callers can always install it as an overlay without
/// worrying about layout cost.
struct BoardTrayView: View {
  @Bindable var store: StoreOf<BoardFeature>

  /// Whether the New-Terminal draft popover is currently showing. Local
  /// rather than TCA-owned so that clicking outside the popover collapses
  /// it back into the tray card without discarding the draft — users
  /// mid-compose shouldn't lose their prompt to a stray click.
  @State private var draftPopoverOpen: Bool = false

  var body: some View {
    if !store.trayCards.isEmpty || store.newTerminalSheet != nil {
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

        if store.newTerminalSheet != nil {
          draftCard
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
      .animation(.spring(response: 0.35, dampingFraction: 0.85), value: store.newTerminalSheet != nil)
      .onChange(of: store.newTerminalSheet != nil) { _, hasDraft in
        // Auto-expand when a draft opens (toolbar +, ⌘N, Rerun, etc.);
        // auto-collapse when the draft state is cleared (create success,
        // Cancel, × on the card, Esc).
        draftPopoverOpen = hasDraft
      }
    }
  }

  @ViewBuilder
  private var draftCard: some View {
    DraftTrayCardView(
      subtitle: draftSubtitle,
      isExpanded: $draftPopoverOpen,
      onDismiss: { store.send(.newTerminalSheet(.dismiss)) },
      popoverContent: {
        if let sheetStore = store.scope(
          state: \.newTerminalSheet, action: \.newTerminalSheet.presented
        ) {
          NewTerminalSheet(store: sheetStore)
            .frame(
              minWidth: 480,
              idealWidth: 520,
              maxWidth: 600,
              minHeight: 420,
              idealHeight: 560,
              maxHeight: 700
            )
        }
      }
    )
  }

  private var draftSubtitle: String {
    guard let draft = store.newTerminalSheet else { return "Configure new session" }
    if let repoID = draft.selectedRepositoryID,
      let repo = draft.availableRepositories[id: repoID] {
      return repo.name
    }
    return "Configure new session"
  }
}

// MARK: - Generic pushed tray card

private struct TrayCardView: View {
  let card: TrayCard
  let onPrimary: () -> Void
  let onDismiss: () -> Void

  @State private var isHovering: Bool = false

  var body: some View {
    Button(action: onPrimary) {
      TrayCardChrome(isHovering: isHovering) {
        HStack(alignment: .top, spacing: 10) {
          Image(systemName: presentation.icon)
            .font(.callout)
            .foregroundStyle(presentation.tint)
            .frame(width: 18, alignment: .center)
            .accessibilityHidden(true)

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
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .help(presentation.helpText)
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

// MARK: - New-Terminal draft card

private struct DraftTrayCardView<PopoverContent: View>: View {
  let subtitle: String
  @Binding var isExpanded: Bool
  let onDismiss: () -> Void
  @ViewBuilder let popoverContent: () -> PopoverContent

  @State private var isHovering: Bool = false

  var body: some View {
    Button {
      isExpanded.toggle()
    } label: {
      TrayCardChrome(isHovering: isHovering) {
        HStack(alignment: .top, spacing: 10) {
          Image(systemName: "plus.rectangle.on.rectangle")
            .font(.callout)
            .foregroundStyle(Color.accentColor)
            .frame(width: 18, alignment: .center)
            .accessibilityHidden(true)

          VStack(alignment: .leading, spacing: 2) {
            Text("New Terminal")
              .font(.callout.weight(.medium))
              .foregroundStyle(.primary)
            Text(subtitle)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          .multilineTextAlignment(.leading)
          .frame(maxWidth: 220, alignment: .leading)

          Button(action: onDismiss) {
            Image(systemName: "xmark")
              .font(.caption2.weight(.semibold))
              .foregroundStyle(.secondary)
              .padding(4)
              .contentShape(Rectangle())
              .accessibilityLabel("Discard draft")
          }
          .buttonStyle(.plain)
          .opacity(isHovering ? 1 : 0.6)
          .help("Discard draft")
        }
      }
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .help(isExpanded ? "Collapse draft" : "Resume draft")
    .popover(isPresented: $isExpanded, arrowEdge: .top) {
      popoverContent()
    }
  }
}

// MARK: - Shared chrome

private struct TrayCardChrome<Content: View>: View {
  let isHovering: Bool
  @ViewBuilder let content: Content

  var body: some View {
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
}

private struct TrayCardPresentation {
  let icon: String
  let tint: Color
  let title: String
  let subtitle: String?
  let helpText: String
}
