import ComposableArchitecture
import SwiftUI

/// A single card on the Matrix Board representing one `AgentSession`.
/// Status is passed in as a `Status` value so the caller (BoardView) can
/// derive it from the terminal manager and bucket cards into sections.
struct SessionCardView: View {
  let session: AgentSession
  let repositoryName: String?
  let status: Status
  let onTap: () -> Void
  let onRemove: () -> Void

  enum Status: Equatable {
    case inProgress
    case waitingOnMe
    case detached
    case fresh  // just created, agent hasn't started busy-looping yet

    var label: String {
      switch self {
      case .inProgress: "Working"
      case .waitingOnMe: "Waiting"
      case .detached: "Detached"
      case .fresh: "Starting"
      }
    }

    var color: Color {
      switch self {
      case .inProgress: .green
      case .waitingOnMe: .orange
      case .detached: .secondary
      case .fresh: .blue
      }
    }

    var systemImage: String {
      switch self {
      case .inProgress: "circle.fill"
      case .waitingOnMe: "exclamationmark.circle.fill"
      case .detached: "moon.zzz.fill"
      case .fresh: "sparkles"
      }
    }
  }

  var body: some View {
    Button(action: onTap) {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 6) {
          Image(systemName: agentIcon)
            .font(.caption)
            .foregroundStyle(agentColor)
          Text(session.agent.displayName)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
          Spacer()
          statusChip
        }

        Text(session.displayName)
          .font(.headline)
          .lineLimit(2, reservesSpace: true)
          .foregroundStyle(.primary)

        Spacer(minLength: 0)

        HStack(spacing: 6) {
          if let repositoryName {
            Label(repositoryName, systemImage: "folder.fill")
              .labelStyle(.titleAndIcon)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          Spacer()
          Text(relativeTimestamp)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .monospacedDigit()
        }
      }
      .padding(14)
      .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
      .background(cardBackground)
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .strokeBorder(status.color.opacity(0.25), lineWidth: 1)
      )
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
    .buttonStyle(.plain)
    .contextMenu {
      Button("Remove", role: .destructive, action: onRemove)
    }
  }

  private var statusChip: some View {
    HStack(spacing: 4) {
      Image(systemName: status.systemImage)
        .font(.caption2)
      Text(status.label)
        .font(.caption2.weight(.semibold))
    }
    .foregroundStyle(status.color)
    .padding(.horizontal, 6)
    .padding(.vertical, 2)
    .background(status.color.opacity(0.12))
    .clipShape(Capsule())
  }

  private var cardBackground: some ShapeStyle {
    AnyShapeStyle(.background.secondary)
  }

  private var agentIcon: String {
    switch session.agent {
    case .claude: "brain"
    case .codex: "terminal.fill"
    }
  }

  private var agentColor: Color {
    switch session.agent {
    case .claude: .purple
    case .codex: .cyan
    }
  }

  private var relativeTimestamp: String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: session.lastActivityAt, relativeTo: Date())
  }
}

#Preview {
  let session = AgentSession(
    repositoryID: "/tmp/repo",
    worktreeID: "/tmp/repo",
    agent: .claude,
    initialPrompt: "Refactor the auth module to use async/await",
    displayName: "Refactor auth module"
  )
  return VStack {
    SessionCardView(
      session: session,
      repositoryName: "my-repo",
      status: .inProgress,
      onTap: {},
      onRemove: {}
    )
    SessionCardView(
      session: session,
      repositoryName: "my-repo",
      status: .waitingOnMe,
      onTap: {},
      onRemove: {}
    )
    SessionCardView(
      session: session,
      repositoryName: "my-repo",
      status: .detached,
      onTap: {},
      onRemove: {}
    )
  }
  .padding()
  .frame(width: 280)
}
