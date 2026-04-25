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
  var onRename: (() -> Void)?
  var onTogglePriority: (() -> Void)? = nil
  var onRerun: (() -> Void)?
  var onResume: (() -> Void)?
  var onResumePicker: (() -> Void)?
  var onPark: (() -> Void)?
  var onUnpark: (() -> Void)?
  var onAutoObserverToggle: (() -> Void)?
  var onAutoObserverPromptChanged: ((String) -> Void)?
  var onAutoObserverRunNow: (() -> Void)?
  /// Right-click → "Debug session…" — opens the debug sheet that spawns
  /// a fresh agent in the supacool repo primed with this session's
  /// trace JSONL.
  var onDebug: (() -> Void)?
  /// Fires once on first appearance so the board reducer can run the
  /// reference scanner (Linear ticket ids, GitHub PR URLs in the
  /// session's transcript).
  var onAppear: (() -> Void)?

  @State private var isHovered: Bool = false
  @State private var isInfoPopoverShown: Bool = false
  @State private var isAutoObserverPopoverShown: Bool = false
  @Environment(\.sessionFootprintStore) private var footprintStore

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 6) {
        Image(systemName: agentIcon)
          .font(.caption)
          .foregroundStyle(agentColor)
          .help(AgentType.displayName(for: session.agent))
        if session.agent != nil {
          sessionIDIndicator
        }
        if let onTogglePriority {
          priorityButton(action: onTogglePriority)
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

      if !session.references.isEmpty {
        referenceChips
      }

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
        if let footprint = footprintStore?.footprint(for: session.id) {
          footprintBadge(footprint: footprint)
        }
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
        .strokeBorder(cardBorderColor, lineWidth: cardBorderWidth)
        .allowsHitTesting(false)
    }
    .overlay {
      if isDormant {
        CrackedGlassOverlay(seed: crackSeed, intensity: crackIntensity)
      }
    }
    .shadow(
      color: session.isPriority ? priorityColor.opacity(isHovered ? 0.24 : 0.16) : .clear,
      radius: session.isPriority ? 10 : 0,
      y: session.isPriority ? 4 : 0
    )
    .clipShape(cardShape)
    .contentShape(cardShape)
    // The card hosts its own info/unpark buttons, so a giant outer Button
    // makes macOS click routing flaky. Keep the card tap as a gesture instead.
    .onTapGesture(perform: onTap)
    .overlay {
      // Show the play overlay for ANY dormant card — parked, idle (detached),
      // interrupted, or disconnected. Clicking always routes through `onTap`
      // (i.e. focusSession → FullScreenTerminalView), which renders the
      // detached state with the "Last response" preview, Rerun, and Resume
      // affordances. Direct-resume / unpark stays available via right-click.
      if isDormant, isHovered {
        dormantHoverOverlay(onPlay: onTap)
      }
    }
    .animation(.spring(response: 0.28, dampingFraction: 0.86), value: status)
    .onHover { isHovered = $0 }
    .task(id: session.id) {
      onAppear?()
    }
    .contextMenu {
      if let onRename {
        Button("Rename…", systemImage: "pencil", action: onRename)
        Divider()
      }
      if let onTogglePriority {
        Button(
          session.isPriority ? "Remove Priority" : "Mark as Priority",
          systemImage: session.isPriority ? "flag.slash" : "flag.fill",
          action: onTogglePriority
        )
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
      if let onDebug {
        Button("Debug session…", systemImage: "ladybug", action: onDebug)
        Divider()
      }
      Button("Remove", systemImage: "trash", role: .destructive, action: onRemove)
    }
  }

  private func priorityButton(action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: session.isPriority ? "flag.fill" : "flag")
        .font(.caption)
        .foregroundStyle(session.isPriority ? priorityColor : .secondary)
    }
    .buttonStyle(.plain)
    .help(
      session.isPriority
        ? "Priority session - click to remove priority"
        : "Mark session as priority"
    )
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
      isAutoObserverPopoverShown.toggle()
    } label: {
      Image(systemName: "sparkles")
        .font(.caption)
        .foregroundStyle(session.autoObserver ? Color.accentColor : Color.secondary)
    }
    .buttonStyle(.plain)
    .help("Auto-responder: auto-answer obvious prompts (click to configure)")
    .popover(isPresented: $isAutoObserverPopoverShown, arrowEdge: .top) {
      AutoObserverPopover(
        session: session,
        onToggle: { onAutoObserverToggle?() },
        onPromptChanged: { onAutoObserverPromptChanged?($0) },
        onRunNow: { onAutoObserverRunNow?() }
      )
    }
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

  /// Shown on hover for any dormant card — a big centered play symbol over
  /// a translucent scrim signalling "the tab is gone, click to open".
  /// Clicking forwards to the regular tap handler so the user lands in the
  /// detached session view (Rerun / Resume / Last response preview).
  private func dormantHoverOverlay(onPlay: @escaping () -> Void) -> some View {
    Button(action: onPlay) {
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
    .help("Open session")
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

  /// Inline chips for ticket ids / PR numbers parsed from the session's
  /// conversation. Shows up to 3; rest collapse to "+N" which opens the
  /// full list via the info popover.
  @AppStorage("supacool.references.linearOrg") private var linearOrgSlug: String = ""

  @ViewBuilder
  private var referenceChips: some View {
    let visible = session.references.prefix(3)
    let overflow = max(0, session.references.count - visible.count)
    HStack(spacing: 4) {
      ForEach(Array(visible), id: \.dedupeKey) { ref in
        ReferenceChip(reference: ref, linearOrgSlug: linearOrgSlug)
      }
      if overflow > 0 {
        Button {
          isInfoPopoverShown = true
        } label: {
          Text("+\(overflow)")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.12))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Show all references")
      }
    }
  }

  private var cardShape: some InsettableShape {
    RoundedRectangle(cornerRadius: 10, style: .continuous)
  }

  /// Cards whose underlying PTY/tab isn't alive right now. Renders
  /// with a frosted "cracked glass" overlay so the board communicates
  /// dormancy at a glance. Covers everything the Board treats as
  /// "tab is gone" — the four states the reducer already groups
  /// together for Rerun / Resume / Reconnect affordances.
  private var isDormant: Bool {
    switch status {
    case .detached, .interrupted, .parked, .disconnected: true
    default: false
    }
  }

  /// Parked is explicit user intent — full strength. The three
  /// involuntary "tab died" states get a slightly lighter touch so
  /// they feel accidental rather than deliberate.
  private var crackIntensity: Double {
    status == .parked ? 1.0 : 0.85
  }

  /// Derive a stable 64-bit seed from the session UUID so each card's
  /// fracture pattern is pinned for its lifetime.
  private var crackSeed: UInt64 {
    var uuid = session.id.uuid
    return withUnsafeBytes(of: &uuid) { $0.load(as: UInt64.self) }
  }

  private var cardBorderColor: Color {
    session.isPriority ? priorityColor.opacity(isHovered ? 0.92 : 0.76) : status.color.opacity(0.25)
  }

  private var cardBorderWidth: CGFloat {
    session.isPriority ? 2 : 1
  }

  private var cardBackground: some ShapeStyle {
    AnyShapeStyle(.background.secondary)
  }

  private var priorityColor: Color { .pink }

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

  /// Compact memory badge shown on the card footer when the shared
  /// footprint store has a sample for this session. Goes orange at
  /// 2 GB and red at 6 GB per-session — picks up the go-vet-Pulumi
  /// class of runaway well before it dominates the machine.
  @ViewBuilder
  private func footprintBadge(
    footprint: ProcessFootprintSnapshot.SessionFootprint
  ) -> some View {
    let tint = Self.footprintTint(for: footprint.aggregatedBytes)
    HStack(spacing: 2) {
      Image(systemName: "memorychip")
        .font(.caption2)
      Text(FootprintChip.formatBytes(footprint.aggregatedBytes))
        .font(.caption2.monospacedDigit())
    }
    .foregroundStyle(tint)
    .padding(.horizontal, 5)
    .padding(.vertical, 2)
    .background(tint.opacity(0.12))
    .clipShape(Capsule())
    .help(footprintHelp(footprint))
  }

  private func footprintHelp(
    _ footprint: ProcessFootprintSnapshot.SessionFootprint
  ) -> String {
    let procs =
      "\(footprint.processCount) process"
      + (footprint.processCount == 1 ? "" : "es")
    let base =
      "\(procs) rooted at PID \(footprint.anchorPID) — "
      + "\(FootprintChip.formatBytes(footprint.aggregatedBytes))"
    if let heavy = footprint.heaviestLeaf, heavy.pid != footprint.anchorPID {
      return base + "\nHeaviest: \(FootprintChip.formatBytes(heavy.rssBytes)) \(heavy.command)"
    }
    return base
  }

  private static func footprintTint(for bytes: UInt64) -> Color {
    if bytes >= 6 * 1024 * 1024 * 1024 { return .red }
    if bytes >= 2 * 1024 * 1024 * 1024 { return .orange }
    return .secondary
  }
}

/// A single reference chip: ticket id or PR number. Click opens in browser.
struct ReferenceChip: View {
  let reference: SessionReference
  let linearOrgSlug: String

  var body: some View {
    Button {
      if let url = reference.url(linearOrgSlug: linearOrgSlug) {
        NSWorkspace.shared.open(url)
      }
    } label: {
      HStack(spacing: 3) {
        if case .pullRequest(_, _, _, let state) = reference, let state {
          Image(systemName: state.systemImage)
            .font(.caption2)
            .foregroundStyle(prStateColor(state))
        }
        Text(reference.chipLabel)
          .font(.caption2.weight(.medium))
          .lineLimit(1)
      }
      .foregroundStyle(.primary.opacity(0.85))
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(chipBackground)
      .clipShape(Capsule())
    }
    .buttonStyle(.plain)
    .help(tooltip)
  }

  private var chipBackground: some ShapeStyle {
    switch reference {
    case .ticket:
      return AnyShapeStyle(Color.blue.opacity(0.15))
    case .pullRequest(_, _, _, let state):
      guard let state else { return AnyShapeStyle(Color.secondary.opacity(0.12)) }
      return AnyShapeStyle(prStateColor(state).opacity(0.15))
    }
  }

  private func prStateColor(_ state: PRState) -> Color {
    switch state {
    case .open: return .green
    case .merged: return .purple
    case .closed: return .red
    case .draft: return .gray
    }
  }

  private var tooltip: String {
    switch reference {
    case .ticket(let id):
      if linearOrgSlug.trimmingCharacters(in: .whitespaces).isEmpty {
        return "\(id) — configure Linear org in Settings → Coding Agents to enable the link"
      }
      return "Open \(id) in Linear"
    case .pullRequest(let owner, let repo, let number, let state):
      let stateLabel = state?.rawValue ?? "loading…"
      return "Open \(owner)/\(repo) #\(number) (\(stateLabel)) on GitHub"
    }
  }
}

#Preview {
  let session = AgentSession(
    repositoryID: "/tmp/repo",
    worktreeID: "/tmp/repo",
    agent: .claude,
    initialPrompt: "Refactor the auth module to use async/await",
    displayName: "Refactor auth module",
    references: [
      .ticket(id: "CEN-1234"),
      .pullRequest(owner: "foo", repo: "bar", number: 42, state: .open),
    ]
  )
  return VStack {
    SessionCardView(
      session: session,
      repositoryName: "my-repo",
      status: .inProgress,
      onTap: {},
      onRemove: {},
      onTogglePriority: {}
    )
    SessionCardView(
      session: session,
      repositoryName: "my-repo",
      status: .waitingOnMe,
      onTap: {},
      onRemove: {},
      onTogglePriority: {}
    )
    SessionCardView(
      session: session,
      repositoryName: "my-repo",
      status: .detached,
      onTap: {},
      onRemove: {},
      onTogglePriority: {}
    )
  }
  .padding()
  .frame(width: 280)
}
