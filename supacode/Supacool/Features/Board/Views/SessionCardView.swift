import ComposableArchitecture
import SwiftUI

/// A single card on the Matrix Board representing one `AgentSession`.
/// Status is passed in as a `Status` value so the caller (BoardView) can
/// derive it from the terminal manager and bucket cards into sections.
struct SessionCardView: View {
  let session: AgentSession
  let repositoryName: String?
  let status: BoardSessionStatus
  let onTap: () -> Void
  let onRemove: () -> Void
  var onRename: (() -> Void)? = nil
  var onRerun: (() -> Void)? = nil
  var onResume: (() -> Void)? = nil
  var onResumePicker: (() -> Void)? = nil
  var onPark: (() -> Void)? = nil
  var onUnpark: (() -> Void)? = nil
  var onAutoObserverToggle: (() -> Void)? = nil
  var onAutoObserverPromptChanged: ((String) -> Void)? = nil

  @State private var isHovered: Bool = false
  @State private var isInfoPopoverShown: Bool = false
  @State private var isAutoObserverPopoverShown: Bool = false
  @State private var autoObserverPromptDraft: String = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 6) {
        Image(systemName: agentIcon)
          .font(.caption)
          .foregroundStyle(agentColor)
        Text(AgentType.displayName(for: session.agent))
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
        if session.agent != nil {
          sessionIDIndicator
        }
        Spacer()
        infoButton
        if onAutoObserverToggle != nil {
          autoObserverButton
        }
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
    .overlay {
      cardShape
        .strokeBorder(status.color.opacity(0.25), lineWidth: 1)
        .allowsHitTesting(false)
    }
    .clipShape(cardShape)
    .contentShape(cardShape)
    // The card hosts its own info/unpark buttons, so a giant outer Button
    // makes macOS click routing flaky. Keep the card tap as a gesture instead.
    .onTapGesture(perform: onTap)
    .overlay {
      if status == .parked, isHovered, let onUnpark {
        parkedHoverOverlay(onUnpark: onUnpark)
      }
    }
    .animation(.spring(response: 0.28, dampingFraction: 0.86), value: status)
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
      Button("Remove", systemImage: "trash", role: .destructive, action: onRemove)
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
        worktreeLabel: nil,
        onRerun: onRerun
      )
    }
  }

  /// Robot button that opens the Auto-Observer configuration popover.
  /// Glows in accent color when the observer is active.
  private var autoObserverButton: some View {
    Button {
      autoObserverPromptDraft = session.autoObserverPrompt
      isAutoObserverPopoverShown.toggle()
    } label: {
      Image(systemName: "sparkles")
        .font(.caption)
        .foregroundStyle(session.autoObserver ? Color.accentColor : Color.secondary)
    }
    .buttonStyle(.plain)
    .help("Auto-observer: auto-answer obvious prompts (click to configure)")
    .popover(isPresented: $isAutoObserverPopoverShown, arrowEdge: .top) {
      autoObserverPopover
    }
  }

  private var autoObserverPopover: some View {
    VStack(alignment: .leading, spacing: 12) {
      Toggle(
        "Auto-observer",
        isOn: Binding(
          get: { session.autoObserver },
          set: { _ in onAutoObserverToggle?() }
        )
      )
      .toggleStyle(.switch)

      VStack(alignment: .leading, spacing: 4) {
        Text("Instructions (optional)")
          .font(.caption)
          .foregroundStyle(.secondary)
        TextEditor(text: $autoObserverPromptDraft)
          .font(.caption.monospaced())
          .frame(width: 260, height: 80)
          .scrollContentBackground(.hidden)
          .background(Color(nsColor: .controlBackgroundColor))
          .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
              .strokeBorder(.separator, lineWidth: 0.5)
          )
          .onChange(of: autoObserverPromptDraft) { _, newValue in
            onAutoObserverPromptChanged?(newValue)
          }
      }
    }
    .padding(14)
  }

  /// Small bookmark glyph signalling whether the agent's native session id
  /// has been captured yet. Filled+green when captured (one-click resume
  /// is available); outlined+tertiary when not (resume will need the
  /// agent's own picker). Only meaningful for agent sessions.
  @ViewBuilder
  private var sessionIDIndicator: some View {
    let captured = session.agentNativeSessionID != nil
    Image(systemName: captured ? "bookmark.fill" : "bookmark")
      .font(.caption2)
      .foregroundStyle(captured ? Color.green : Color.secondary.opacity(0.6))
      .help(
        captured
          ? "Session id captured — resume is one click"
          : "No session id captured yet — resume will open the agent's picker"
      )
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
        .lineLimit(1)
    }
    .foregroundStyle(status.color)
    .padding(.horizontal, 6)
    .padding(.vertical, 2)
    .background(status.color.opacity(0.12))
    .clipShape(Capsule())
    .fixedSize()
  }

  private var cardShape: some InsettableShape {
    RoundedRectangle(cornerRadius: 10, style: .continuous)
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
