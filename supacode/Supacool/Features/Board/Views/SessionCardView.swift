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
  var onRename: (() -> Void)? = nil
  var onRerun: (() -> Void)? = nil
  var onResume: (() -> Void)? = nil
  var onResumePicker: (() -> Void)? = nil
  var onPark: (() -> Void)? = nil
  var onUnpark: (() -> Void)? = nil

  @State private var isHovered: Bool = false
  @State private var isInfoPopoverShown: Bool = false

  enum Status: Equatable {
    case inProgress
    case waitingOnMe
    case awaitingInput  // agent paused on a permission prompt / question
    case detached
    case interrupted  // was busy when the app went away; agent's turn lost
    case fresh  // just created, agent hasn't started busy-looping yet
    case parked  // user explicitly parked; PTY freed, metadata preserved

    var label: String {
      switch self {
      case .inProgress: "Working"
      case .waitingOnMe: "Waiting"
      case .awaitingInput: "Wants Input"
      case .detached: "Idle"
      case .interrupted: "Interrupted"
      case .fresh: "Starting"
      case .parked: "Parked"
      }
    }

    var color: Color {
      switch self {
      case .inProgress: .green
      case .waitingOnMe: .orange
      case .awaitingInput: .orange
      case .detached: .secondary
      case .interrupted: .yellow
      case .fresh: .blue
      case .parked: .secondary
      }
    }

    var systemImage: String {
      switch self {
      case .inProgress: "circle.fill"
      case .waitingOnMe: "exclamationmark.circle.fill"
      case .awaitingInput: "hand.raised.fill"
      case .detached: "moon.zzz.fill"
      case .interrupted: "exclamationmark.triangle.fill"
      case .fresh: "sparkles"
      case .parked: "parkingsign"
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
          Text(AgentType.displayName(for: session.agent))
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
          Spacer()
          infoButton
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
      .overlay {
        if status == .parked, isHovered, let onUnpark {
          parkedHoverOverlay(onUnpark: onUnpark)
        }
      }
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .contextMenu {
      if let onRename {
        Button("Rename…", systemImage: "pencil", action: onRename)
        Divider()
      }
      if let onResume {
        Button("Resume Session", systemImage: "play.circle", action: onResume)
      }
      if let onResumePicker {
        Button("Resume via Picker…", systemImage: "play.circle", action: onResumePicker)
      }
      if let onRerun {
        Button("Rerun with Same Prompt", systemImage: "arrow.clockwise", action: onRerun)
      }
      if let onPark {
        Button("Park", systemImage: "parkingsign", action: onPark)
      }
      if let onUnpark {
        Button("Unpark", systemImage: "play.circle", action: onUnpark)
      }
      if onResume != nil || onResumePicker != nil || onRerun != nil
        || onPark != nil || onUnpark != nil
      {
        Divider()
      }
      Button("Remove", role: .destructive, action: onRemove)
    }
  }

  /// Small ⓘ button on the card header that shows the session's initial
  /// config (prompt, agent, repo, worktree, etc.). Uses `.popover` so the
  /// click doesn't fall through to the card's `onTap` (which would enter
  /// the full-screen terminal).
  private var infoButton: some View {
    Button {
      isInfoPopoverShown.toggle()
    } label: {
      Image(systemName: "info.circle")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .buttonStyle(.plain)
    .help("Show session details")
    .popover(isPresented: $isInfoPopoverShown, arrowEdge: .top) {
      SessionInfoPopover(
        session: session,
        repositoryName: repositoryName,
        worktreeLabel: nil
      )
    }
  }

  /// Shown on hover for parked cards — a big centered play symbol over a
  /// translucent scrim. Clicking it unparks the session directly, so the
  /// user doesn't have to reach for the right-click menu.
  private func parkedHoverOverlay(onUnpark: @escaping () -> Void) -> some View {
    Button(action: onUnpark) {
      ZStack {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(.background.opacity(0.55))
        Image(systemName: "play.circle.fill")
          .font(.system(size: 44, weight: .semibold))
          .foregroundStyle(.primary, .background)
          .symbolRenderingMode(.palette)
      }
    }
    .buttonStyle(.plain)
    .help("Unpark session")
    .transition(.opacity)
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
    case .none: "apple.terminal"
    }
  }

  private var agentColor: Color {
    switch session.agent {
    case .claude: .purple
    case .codex: .cyan
    case .none: .secondary
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
