import SwiftUI

/// Small per-terminal agent chip — the header `agentChip`'s new home now
/// that a session can run several agents. Rendered bottom-trailing on
/// each agent pane of the full-screen terminal, and reused (icon + dot)
/// by the session tab strip.
///
/// Shows the agent's icon + name tinted with the agent color, plus a
/// live-activity dot: green while that terminal's agent is working,
/// orange when it wants input, gray when idle.
struct SessionTerminalBadge: View {
  let agent: AgentType?
  let activity: AgentActivity

  var body: some View {
    HStack(spacing: 4) {
      AgentIconView(agent: agent, size: 12)
      Text(AgentType.displayName(for: agent))
        .font(.caption.weight(.medium))
        .foregroundStyle(agentColor)
      ActivityDot(activity: activity)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .background(.background.secondary.opacity(0.85))
    .background(agentColor.opacity(0.12))
    .clipShape(Capsule())
    .help("\(AgentType.displayName(for: agent)) in this pane — \(activityDescription)")
    .accessibilityLabel(
      "\(AgentType.displayName(for: agent)) — \(activityDescription)"
    )
  }

  private var agentColor: Color {
    AgentType.tintColor(for: agent)
  }

  private var activityDescription: String {
    switch activity {
    case .working: "working"
    case .wantsInput: "wants input"
    case .deferredWork: "holding for background work"
    case .idle: "idle"
    }
  }

  /// The bare activity dot, reused by the session tab strip labels.
  struct ActivityDot: View {
    let activity: AgentActivity

    var body: some View {
      Circle()
        .fill(color)
        .frame(width: 6, height: 6)
        .accessibilityHidden(true)
    }

    private var color: Color {
      switch activity {
      case .working, .deferredWork: .green
      case .wantsInput: .orange
      case .idle: Color.secondary.opacity(0.5)
      }
    }
  }
}
