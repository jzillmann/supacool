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
  /// Pass-through from `BoardRootView`. Needed because the
  /// `.sessionSpawnFailed` tap reopens the New Terminal sheet, which
  /// wants the candidate repo list to pick a default and resolve the
  /// snapshot's `repositoryID` against — same plumbing as DraftPillRow.
  /// Defaults to `[]` so the existing `BoardTrayView(store:)` call sites
  /// keep working; only the tray rendered over the board passes a real list.
  var repositories: IdentifiedArrayOf<Repository> = []

  var body: some View {
    if !store.trayCards.isEmpty {
      // Computed once per render: error cards' Debug icon is gated on
      // whether any registered repo holds `supacool.xcodeproj`. Cheap
      // (a few file-exists checks against the registered roots) and
      // the tray is rarely populated.
      let supacoolRegistered =
        SupacoolDebugSupport.findSupacoolRepository(in: Array(repositories)) != nil
      HStack(alignment: .bottom, spacing: 10) {
        ForEach(store.trayCards) { card in
          TrayCardView(
            card: card,
            onPrimary: {
              store.send(
                .trayCardPrimaryTapped(
                  id: card.id,
                  repositories: Array(repositories)
                )
              )
            },
            onSecondary: card.kind.hasSecondaryAction
              ? { store.send(.trayCardSecondaryTapped(id: card.id)) }
              : nil,
            onCopy: card.kind.errorContent != nil
              ? { store.send(.trayCardCopyTapped(id: card.id)) }
              : nil,
            onDebug: card.kind.errorContent != nil && supacoolRegistered
              ? {
                store.send(
                  .trayCardDebugTapped(
                    id: card.id,
                    repositories: Array(repositories)
                  )
                )
              }
              : nil,
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
  let onSecondary: (() -> Void)?
  let onCopy: (() -> Void)?
  let onDebug: (() -> Void)?
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
    .help(presentation.tooltipText)
    .contextMenu {
      if let detail = presentation.subtitle {
        Button("Copy details") {
          let pb = NSPasteboard.general
          pb.clearContents()
          pb.setString("\(presentation.title)\n\(detail)", forType: .string)
        }
      }
    }
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

      if let onSecondary, let secondaryTitle = presentation.secondaryTitle {
        Button(secondaryTitle, action: onSecondary)
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
          .help(presentation.secondaryHelp ?? secondaryTitle)
      }

      if let onCopy {
        iconButton(
          systemName: "doc.on.doc",
          accessibilityLabel: "Copy error",
          help: "Copy this error to the clipboard",
          action: onCopy
        )
      }

      if let onDebug {
        iconButton(
          systemName: "ladybug",
          accessibilityLabel: "Debug this error",
          help: "Start a Supacool debug session on this error",
          action: onDebug
        )
      }

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

  private func iconButton(
    systemName: String,
    accessibilityLabel: String,
    help: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(4)
        .contentShape(Rectangle())
        .accessibilityLabel(accessibilityLabel)
    }
    .buttonStyle(.plain)
    .opacity(isHovering ? 1 : 0.7)
    .help(help)
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
          : "Drift in \(Self.describe(slots)).",
        helpText: "Open Settings → Coding Agents to inspect.",
        secondaryTitle: "Reinstall",
        secondaryHelp: "Reinstall the listed hooks now"
      )
    case .sessionCreating(_, let displayName):
      return TrayCardPresentation(
        icon: "terminal.fill",  // unused — leadingIndicator shows a spinner
        tint: Color.secondary,
        title: "Starting session",
        subtitle: displayName,
        helpText: "Open this session"
      )
    case .hookInstallFailed(let slot, let message):
      return TrayCardPresentation(
        icon: "xmark.octagon.fill",
        tint: .red,
        title: "\(Self.label(for: slot)) install failed",
        subtitle: message,
        helpText: "Open Settings → Coding Agents to retry."
      )
    case .worktreeDeleteFailed(let path, let message):
      let folder = URL(fileURLWithPath: path).lastPathComponent
      return TrayCardPresentation(
        icon: "exclamationmark.triangle.fill",
        tint: .orange,
        title: "Couldn't remove worktree",
        subtitle: "\(folder) — \(message)",
        helpText: "The directory may still be on disk. Dismiss to clear."
      )
    case .sessionSpawnFailed(let displayName, let message, let draftSnapshot):
      return TrayCardPresentation(
        icon: "xmark.octagon.fill",
        tint: .red,
        title: "Couldn't start \(displayName)",
        subtitle: message,
        helpText: draftSnapshot == nil
          ? "Tap to dismiss."
          : "Tap to reopen the New Terminal sheet with your values pre-filled."
      )
    }
  }

  private static func label(for slot: AgentHookSlot) -> String {
    switch slot {
    case .claudeProgress: "Claude Progress"
    case .claudeNotifications: "Claude Notifications"
    case .codexProgress: "Codex Progress"
    case .codexNotifications: "Codex Notifications"
    case .piExtension: "Pi Extension"
    }
  }

  private static func describe(_ slots: [AgentHookSlot]) -> String {
    let labels = slots.map { slot -> String in
      switch slot {
      case .claudeProgress: "Claude Progress"
      case .claudeNotifications: "Claude Notifications"
      case .codexProgress: "Codex Progress"
      case .codexNotifications: "Codex Notifications"
      case .piExtension: "Pi Extension"
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
  var secondaryTitle: String?
  var secondaryHelp: String?

  /// Hover tooltip — shows the full subtitle (which the in-card label
  /// truncates to 2 lines) above the call-to-action hint, so users can
  /// read long error messages without leaving the board.
  var tooltipText: String {
    guard let subtitle, !subtitle.isEmpty else { return helpText }
    return "\(subtitle)\n\n\(helpText)"
  }
}
