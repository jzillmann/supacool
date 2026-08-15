import SwiftUI

/// Tab strip rendered above `SingleSessionTerminalView` when a session
/// holds more than one terminal. The agent (primary) is pinned first and
/// non-closable; auxiliary shells appear after it and can be closed.
///
/// Intentionally minimal — the board is the user's main "tab bar", so
/// this strip stays tiny and never spans the full window chrome.
struct SessionTerminalTabStrip: View {
  let terminals: [SessionTerminal]
  let primaryTerminalID: UUID
  let activeTerminalID: UUID
  /// Live activity for a terminal's chip dot. Nil = no dot (shells).
  var activity: ((SessionTerminal) -> AgentActivity?)?
  let onSelect: (UUID) -> Void
  let onClose: (UUID) -> Void
  let onAdd: () -> Void
  /// Right-click "Convert to split pane" on a non-primary tab — moves
  /// its terminal into the primary tab's split tree.
  var onConvertToSplit: ((UUID) -> Void)?

  var body: some View {
    HStack(spacing: 6) {
      ForEach(terminals) { terminal in
        tab(terminal)
      }
      addButton
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(.background.tertiary)
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(Color.secondary.opacity(0.18))
        .frame(height: 1)
    }
  }

  @ViewBuilder
  private func tab(_ terminal: SessionTerminal) -> some View {
    let isActive = terminal.id == activeTerminalID
    let isPrimary = terminal.id == primaryTerminalID
    Button {
      onSelect(terminal.id)
    } label: {
      HStack(spacing: 5) {
        if terminal.role == .agent {
          AgentIconView(agent: terminal.agent, size: 10)
        } else {
          Image(systemName: "terminal.fill")
            .font(.system(size: 10, weight: .semibold))
            .accessibilityLabel("Shell terminal")
        }
        Text(label(for: terminal))
          .font(.caption.weight(.medium))
          .lineLimit(1)
        if let liveActivity = activity?(terminal) {
          SessionTerminalBadge.ActivityDot(activity: liveActivity)
        }
        if !isPrimary {
          Button {
            onClose(terminal.id)
          } label: {
            Image(systemName: "xmark")
              .font(.system(size: 8, weight: .bold))
              .foregroundStyle(.secondary)
              .padding(2)
              .contentShape(Rectangle())
              .accessibilityLabel("Close this shell tab")
          }
          .buttonStyle(.plain)
          .help("Close this shell tab")
        }
      }
      .foregroundStyle(isActive ? Color.primary : Color.secondary)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(
        Capsule(style: .continuous)
          .fill(isActive ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08))
      )
    }
    .buttonStyle(.plain)
    .help(
      terminal.role == .agent
        ? "\(AgentType.displayName(for: terminal.agent)) terminal"
        : "Shell terminal"
    )
    .contextMenu {
      if !isPrimary, let onConvertToSplit {
        Button {
          onConvertToSplit(terminal.id)
        } label: {
          Label("Convert to Split Pane", systemImage: "rectangle.split.2x1")
        }
        .help("Move this terminal into the primary tab as a split pane")
      }
    }
  }

  private var addButton: some View {
    Button(action: onAdd) {
      Image(systemName: "plus")
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(.secondary)
        .accessibilityLabel("Add a shell tab to this session")
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
          Capsule(style: .continuous).fill(Color.secondary.opacity(0.08))
        )
    }
    .buttonStyle(.plain)
    .help("Add a shell tab to this session")
  }

  private func label(for terminal: SessionTerminal) -> String {
    if let custom = terminal.displayName, !custom.isEmpty { return custom }
    switch terminal.role {
    case .agent:
      return AgentType.displayName(for: terminal.agent)
    case .shell:
      return "Shell"
    }
  }
}
