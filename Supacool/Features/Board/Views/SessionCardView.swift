import ComposableArchitecture
import SwiftUI

/// A single card on the Matrix Board representing one `AgentSession`.
/// Status is passed in as a `Status` value so the caller (BoardView) can
/// derive it from the terminal manager and bucket cards into sections.
struct SessionCardView: View {
  let session: AgentSession
  let repositoryName: String?
  var pullRequest: GithubPullRequest? = nil
  let status: BoardSessionStatus
  var serverLifecycle: BoardFeature.ServerLifecycleViewState? = nil
  var onServerLifecycleRefresh: (() -> Void)? = nil
  var onServerLifecycleStart: (() -> Void)? = nil
  var onServerLifecycleStop: (() -> Void)? = nil
  /// True for Standby (formerly "Park as Active"): the user parked this
  /// session with intent to come back to it. Persisted on the session,
  /// so after a crash/relaunch the card still reads as Standby even
  /// though no live PTY/tab exists yet.
  var isActiveParked: Bool = false
  var debugLinkTitle: String? = nil
  var onDebugLinkTap: (() -> Void)? = nil
  let onTap: () -> Void
  let onRemove: () -> Void
  var onRename: (() -> Void)?
  var onTogglePriority: (() -> Void)? = nil
  /// Sets the session's manual status override. Pass `nil` to clear.
  var onSetStatusOverride: ((BoardSessionStatus?) -> Void)? = nil
  var onRerun: (() -> Void)?
  var onResume: (() -> Void)?
  /// Resume without setting the focused session — used by the dormant-card
  /// hover play icon so the user stays on the dashboard.
  var onResumeInPlace: (() -> Void)?
  var onResumePicker: (() -> Void)?
  var onResumeSelected: (() -> Void)?
  var selectedResumeCount: Int = 0
  var selectedPickerResumeCount: Int = 0
  var onPark: (() -> Void)?
  var onParkActive: (() -> Void)?
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
  /// Called when the PR reference popover opens so visible PR states get
  /// a cache-throttled refresh without adding extra chrome to the popover.
  var onReferencesPopoverOpened: (() -> Void)?
  /// Unlink a wrongly-associated Linear ticket / GitHub PR reference.
  var onRemoveReference: ((SessionReference) -> Void)?
  /// Latest checks/Greptile snapshot per PR reference (dedupeKey), from
  /// `BoardFeature.State.prReferenceSnapshots`. Callers pass the subset
  /// for this session's references so unrelated PR updates don't re-render
  /// every card.
  var prReferenceSnapshots: [String: PullRequestSnapshot] = [:]

  @State private var isHovered: Bool = false
  @State private var isInfoPopoverShown: Bool = false
  @State private var isAutoObserverPopoverShown: Bool = false
  @Environment(\.sessionFootprintStore) private var footprintStore

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 6) {
        AgentIconView(agent: session.agent, size: 12)
          .help(AgentType.displayName(for: session.agent))
        if session.agent != nil {
          sessionIDIndicator
        }
        if let onTogglePriority {
          priorityButton(action: onTogglePriority)
        }
        if !session.auxiliaryTerminals.isEmpty {
          shellCompositionPill
        }
        Spacer()
        infoButton
        if onAutoObserverToggle != nil {
          autoObserverButton
        }
        if let serverLifecycle {
          serverLifecycleChip(serverLifecycle)
        }
        statusChip
      }

      Text(session.displayName)
        .font(.headline)
        .lineLimit(2, reservesSpace: true)
        .foregroundStyle(.primary)

      if let debugLinkTitle, let onDebugLinkTap {
        debugLinkChip(title: debugLinkTitle, onTap: onDebugLinkTap)
      }

      if let model = PullRequestStatusModel(pullRequest: pullRequest) {
        pullRequestStatus(model)
      }

      if !session.references.isEmpty {
        referenceChips
      }

      Spacer(minLength: 0)

      footer
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
    .shadow(
      color: checksGlowColor.opacity(isHovered ? 0.55 : 0.40),
      radius: checksGlowColor == .clear ? 0 : 12,
      y: 0
    )
    .clipShape(cardShape)
    .contentShape(cardShape)
    // The card hosts its own info/unpark buttons, so a giant outer Button
    // makes macOS click routing flaky. Keep the card tap as a gesture instead.
    .onTapGesture(perform: onTap)
    .overlay {
      // Show the hover overlay for ANY dormant card — parked, idle (detached),
      // interrupted, or disconnected. The play icon (when available) resumes
      // the session in place; the info icon routes through `onTap` (i.e.
      // focusSession → FullScreenTerminalView) for the full detail view with
      // Rerun / Resume via Picker / Last response preview.
      if isDormant, isHovered {
        dormantHoverOverlay(onPlay: dormantPlayAction, onInfo: onTap)
      }
    }
    .animation(.spring(response: 0.28, dampingFraction: 0.86), value: status)
    .onHover { isHovered = $0 }
    .task(id: session.id) {
      onAppear?()
    }
    .contextMenu {
      if let onResumeSelected {
        Button(
          selectedResumeTitle,
          systemImage: "play.circle.fill",
          action: onResumeSelected
        )
        .help(selectedResumeHelp)
        Divider()
      }
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
      if let onSetStatusOverride {
        Menu("Set Status", systemImage: "circle.dashed") {
          Button("Working", systemImage: BoardSessionStatus.inProgress.systemImage) {
            onSetStatusOverride(.inProgress)
          }
          Button("Waiting", systemImage: BoardSessionStatus.waitingOnMe.systemImage) {
            onSetStatusOverride(.waitingOnMe)
          }
          Button("Wants Input", systemImage: BoardSessionStatus.awaitingInput.systemImage) {
            onSetStatusOverride(.awaitingInput)
          }
          Button(
            BoardSessionStatus.waitingForChecks.label,
            systemImage: BoardSessionStatus.waitingForChecks.systemImage
          ) {
            onSetStatusOverride(.waitingForChecks)
          }
          if session.manualStatusOverride != nil {
            Divider()
            Button("Clear Override", systemImage: "xmark.circle") {
              onSetStatusOverride(nil)
            }
          }
        }
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
      if let onParkActive {
        Button("Standby", systemImage: "bolt.circle", action: onParkActive)
      }
      if let onUnpark {
        Button("Unpark", systemImage: "play.circle", action: onUnpark)
      }
      if onResume != nil || onResumePicker != nil || onRerun != nil
        || onPark != nil || onParkActive != nil || onUnpark != nil
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

  /// Compact "+N sh" pill — shows when the session has auxiliary shell
  /// terminals beyond its agent. Purely informational; opening the card
  /// still routes straight to the agent terminal.
  private var shellCompositionPill: some View {
    let count = session.auxiliaryTerminals.count
    return HStack(spacing: 2) {
      Image(systemName: "terminal.fill")
        .font(.system(size: 9, weight: .semibold))
      Text("+\(count)")
        .font(.caption2.weight(.semibold).monospacedDigit())
    }
    .foregroundStyle(.secondary)
    .padding(.horizontal, 5)
    .padding(.vertical, 1)
    .background(Color.secondary.opacity(0.12))
    .clipShape(Capsule())
    .help("\(count) auxiliary shell tab\(count == 1 ? "" : "s") in this session")
  }

  /// Small bookmark glyph signalling whether the agent's native session id
  /// has been captured yet. Filled+green when captured (one-click resume
  /// is available); outlined+tertiary when not (resume will need the
  /// agent's own picker). Only meaningful for agent sessions.
  @ViewBuilder
  private var sessionIDIndicator: some View {
    let captured = BoardResumeEligibility.hasCapturedNativeSessionID(session)
    Image(systemName: captured ? "bookmark.fill" : "bookmark")
      .font(.caption2)
      .foregroundStyle(sessionIDIndicatorColor(captured: captured))
      .help(
        captured
          ? "Session id captured — resume is one click"
          : "No session id captured yet — resume will open the agent's picker"
      )
  }

  private var selectedResumeTitle: String {
    let noun = selectedResumeCount == 1 ? "Session" : "Sessions"
    guard selectedPickerResumeCount > 0 else {
      return "Resume \(selectedResumeCount) Selected \(noun)"
    }
    return "Resume \(selectedResumeCount) Selected \(noun) (\(selectedPickerResumeCount) via Picker)"
  }

  private var selectedResumeHelp: String {
    guard selectedPickerResumeCount > 0 else {
      return "Resume the selected sessions with captured session ids."
    }
    let noun = selectedPickerResumeCount == 1 ? "session" : "sessions"
    return "Resume captured sessions directly; open the agent picker for "
      + "\(selectedPickerResumeCount) selected \(noun) without a captured id."
  }

  private func sessionIDIndicatorColor(captured: Bool) -> Color {
    if captured { return .green }
    return isDormant ? .orange : Color.secondary.opacity(0.6)
  }

  /// Resume action for the hover play icon. Only set when the caller can
  /// guarantee an in-place resume (no navigation to the full-screen view),
  /// so the dashboard stays put. When nil the play icon is hidden — only
  /// the info icon stays, so the user can still drop into the detail view
  /// for Rerun / Resume via Picker.
  private var dormantPlayAction: (() -> Void)? {
    onResumeInPlace
  }

  /// Shown on hover for any dormant card — a play icon that resumes the
  /// session in place (when possible), and an info icon that opens the
  /// detail view with Rerun / Resume via Picker / Last response preview.
  private func dormantHoverOverlay(
    onPlay: (() -> Void)?,
    onInfo: @escaping () -> Void
  ) -> some View {
    ZStack {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(.background.opacity(0.55))
      HStack(spacing: 24) {
        if let onPlay {
          dormantHoverButton(
            systemImage: "play.circle.fill",
            help: "Resume session",
            action: onPlay
          )
        }
        dormantHoverButton(
          systemImage: "info.circle.fill",
          help: "Open session details",
          action: onInfo
        )
      }
    }
    .transition(.opacity)
  }

  private func dormantHoverButton(
    systemImage: String,
    help: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: 44, weight: .semibold))
        .foregroundStyle(.primary, .background)
        .symbolRenderingMode(.palette)
    }
    .buttonStyle(.plain)
    .help(help)
  }

  private var footer: some View {
    HStack(spacing: 8) {
      if let footprint = footprintStore?.footprint(for: session.id) {
        footprintBadge(footprint: footprint)
      }
      Spacer(minLength: 8)
      Text(relativeTimestamp)
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }
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

  private func serverLifecycleChip(_ lifecycle: BoardFeature.ServerLifecycleViewState) -> some View {
    Button {
      switch lifecycle.status {
      case .running:
        onServerLifecycleStop?()
      case .stopped:
        onServerLifecycleStart?()
      case .unknown, .failed:
        onServerLifecycleRefresh?()
      case .checking, .starting, .stopping:
        break
      }
    } label: {
      HStack(spacing: 4) {
        Image(systemName: lifecycle.status.systemImage)
          .font(.caption2)
        Text(lifecycle.status.label)
          .font(.caption2.weight(.semibold))
          .lineLimit(1)
      }
      .foregroundStyle(serverLifecycleColor(lifecycle.status))
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(serverLifecycleColor(lifecycle.status).opacity(0.12))
      .clipShape(Capsule())
    }
    .buttonStyle(.plain)
    .disabled(lifecycle.status.isBusy)
    .help(serverLifecycleHelp(lifecycle))
    .fixedSize()
  }

  private func serverLifecycleHelp(_ lifecycle: BoardFeature.ServerLifecycleViewState) -> String {
    var parts = ["\(lifecycle.name): \(lifecycle.status.label)"]
    if let detail = lifecycle.detail, !detail.isEmpty {
      parts.append(detail)
    }
    switch lifecycle.status {
    case .running:
      parts.append("Click to stop.")
    case .stopped:
      parts.append("Click to start.")
    case .unknown, .failed:
      parts.append("Click to refresh status.")
    case .checking, .starting, .stopping:
      break
    }
    return parts.joined(separator: "\n")
  }

  private func serverLifecycleColor(_ status: BoardFeature.ServerLifecycleStatus) -> Color {
    switch status {
    case .running: .green
    case .stopped: .secondary
    case .unknown, .checking: .yellow
    case .starting: .blue
    case .stopping: .orange
    case .failed: .red
    }
  }

  /// Inline chips for parsed work references. Keeps the obvious Linear
  /// ticket visible and collapses multiple PRs into a stacked dropdown chip.
  private var referenceChips: some View {
    SessionReferenceSummaryChips(
      references: session.references,
      onPullRequestsPopoverOpened: onReferencesPopoverOpened,
      onRemoveReference: onRemoveReference,
      prReferenceSnapshots: prReferenceSnapshots
    )
  }

  private func pullRequestStatus(_ model: PullRequestStatusModel) -> some View {
    PullRequestStatusButton(model: model)
      .font(.caption)
      .lineLimit(1)
  }

  private func debugLinkChip(title: String, onTap: @escaping () -> Void) -> some View {
    Button(action: onTap) {
      HStack(spacing: 4) {
        Image(systemName: "ladybug.fill")
          .font(.caption2)
        Text(title)
          .font(.caption2.weight(.medium))
          .lineLimit(1)
      }
      .foregroundStyle(Color.pink)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(Color.pink.opacity(0.12))
      .clipShape(Capsule())
    }
    .buttonStyle(.plain)
    .help("Jump to linked debug/source session")
  }

  private var cardShape: some InsettableShape {
    RoundedRectangle(cornerRadius: 10, style: .continuous)
  }

  /// Cards whose underlying PTY/tab isn't alive right now. Renders
  /// with a frosted "cracked glass" overlay so the board communicates
  /// dormancy at a glance. Standby cards (formerly "Park as Active") render
  /// full-strength because the user explicitly intends to come back to them —
  /// even post-crash, when the tab itself is no longer alive.
  private var isDormant: Bool {
    if isActiveParked { return false }
    switch status {
    case .detached, .interrupted, .parked, .disconnected: return true
    default: return false
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

  /// Glow tint when the worktree PR's CI just finished. Green for an
  /// all-green run, red when at least one check failed. `.clear` (no
  /// glow) while CI is still running or when there's no PR.
  private var checksGlowColor: Color {
    switch BoardPullRequestChecks.outcome(pullRequest) {
    case .completed(let allPassed): allPassed ? .green : .red
    case .pending, .unknown: .clear
    }
  }

  private var cardBorderWidth: CGFloat {
    session.isPriority ? 2 : 1
  }

  private var cardBackground: some ShapeStyle {
    AnyShapeStyle(.background.secondary)
  }

  private var priorityColor: Color { .pink }

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
    HStack(spacing: 4) {
      Image(systemName: "memorychip")
        .font(.caption2)
        .accessibilityHidden(true)
      Text(FootprintChip.formatBytes(footprint.aggregatedBytes))
        .font(.caption2.monospacedDigit())
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }
    .foregroundStyle(tint)
    .padding(.horizontal, 6)
    .padding(.vertical, 2)
    .background(tint.opacity(0.12))
    .clipShape(Capsule())
    .fixedSize(horizontal: true, vertical: false)
    .accessibilityLabel("Memory footprint: \(FootprintChip.formatBytes(footprint.aggregatedBytes))")
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

/// A single reference chip: ticket id or PR number. Click opens the reference externally.
struct ReferenceChip: View {
  let reference: SessionReference
  let linearOrgSlug: String
  var onTap: (() -> Void)? = nil
  /// Unlink a wrongly-associated reference. Nil hides the affordance.
  var onRemove: (() -> Void)? = nil
  /// Latest checks/Greptile snapshot for a PR reference. Nil (and ignored
  /// for tickets) hides the CI glyph and score badge.
  var prSnapshot: PullRequestSnapshot? = nil

  var body: some View {
    Button {
      onTap?()
      if let url = reference.url(linearOrgSlug: linearOrgSlug) {
        NSWorkspace.shared.open(url)
      }
    } label: {
      HStack(spacing: 3) {
        if case .pullRequest(_, _, _, let state, _) = reference, let state {
          Image(systemName: state.systemImage)
            .font(.caption2)
            .foregroundStyle(prStateColor(state))
        }
        Text(reference.chipLabel)
          .font(.caption2.weight(.medium))
          .lineLimit(1)
        if case .pullRequest = reference, let prSnapshot {
          PRChecksGlyph(checks: prSnapshot.statusChecks)
          GreptileScoreBadge(score: prSnapshot.greptileScore)
        }
      }
      .foregroundStyle(.primary.opacity(0.85))
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(chipBackground)
      .clipShape(Capsule())
    }
    .buttonStyle(.plain)
    .help(tooltip)
    .contextMenu {
      if let onRemove {
        Button(role: .destructive, action: onRemove) {
          Label("Remove link", systemImage: "link.badge.minus")
        }
      }
    }
  }

  private var chipBackground: some ShapeStyle {
    switch reference {
    case .ticket:
      return AnyShapeStyle(Color.blue.opacity(0.15))
    case .pullRequest(_, _, _, let state, _):
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
      return linearOrgSlug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? "Open \(id) in the Linear desktop app"
        : "Open \(id) in Linear"
    case .pullRequest(let owner, let repo, let number, let state, let title):
      let stateLabel = state?.rawValue ?? "loading…"
      let statusSuffix = prSnapshot?.statusHelpSuffix ?? ""
      let titleSuffix = (title?.isEmpty ?? true) ? "" : " — \(title ?? "")"
      return "Open \(owner)/\(repo) #\(number) (\(stateLabel)\(statusSuffix))\(titleSuffix) on GitHub"
    }
  }
}

/// Compact reference summary used on board cards and the terminal header.
/// Linear tickets stay visible; multiple PRs collapse into one stacked chip
/// with a dropdown list so PR-heavy sessions do not flood the layout.
struct SessionReferenceSummaryChips: View {
  let references: [SessionReference]
  var onPullRequestsPopoverOpened: (() -> Void)? = nil
  /// Unlink a wrongly-associated reference. Nil hides the affordance.
  var onRemoveReference: ((SessionReference) -> Void)? = nil
  /// Latest checks/Greptile snapshot per PR reference (dedupeKey). Empty
  /// hides the CI/score indicators on chips and popover rows.
  var prReferenceSnapshots: [String: PullRequestSnapshot] = [:]

  @AppStorage("supacool.references.linearOrg") private var linearOrgSlug: String = ""

  private var tickets: [SessionReference] {
    references.filter {
      if case .ticket = $0 { return true }
      return false
    }
  }

  private var pullRequests: [SessionReference] {
    references.filter {
      if case .pullRequest = $0 { return true }
      return false
    }
  }

  var body: some View {
    HStack(spacing: 4) {
      if let ticket = tickets.first {
        ReferenceChip(
          reference: ticket,
          linearOrgSlug: linearOrgSlug,
          onRemove: onRemoveReference.map { remove in { remove(ticket) } }
        )
      }
      if tickets.count > 1 {
        ReferenceStackChip(
          kind: .tickets,
          references: Array(tickets.dropFirst()),
          linearOrgSlug: linearOrgSlug,
          onRemoveReference: onRemoveReference
        )
      }
      if pullRequests.count == 1, let pullRequest = pullRequests.first {
        ReferenceChip(
          reference: pullRequest,
          linearOrgSlug: linearOrgSlug,
          onTap: onPullRequestsPopoverOpened,
          onRemove: onRemoveReference.map { remove in { remove(pullRequest) } },
          prSnapshot: prReferenceSnapshots[pullRequest.dedupeKey]
        )
      } else if pullRequests.count > 1 {
        ReferenceStackChip(
          kind: .pullRequests,
          references: pullRequests,
          linearOrgSlug: linearOrgSlug,
          onPopoverOpened: onPullRequestsPopoverOpened,
          onRemoveReference: onRemoveReference,
          prReferenceSnapshots: prReferenceSnapshots
        )
      }
    }
    .lineLimit(1)
    .fixedSize(horizontal: true, vertical: false)
  }
}

/// Presentation model for the reference stack popover.
///
/// Once merged or closed PR noise reaches the threshold, those settled PRs
/// collapse into their own expandable rows so active/open PRs stay
/// immediately visible. Merged and closed collapse independently.
nonisolated struct ReferenceStackPopoverPresentation: Equatable, Sendable {
  /// Collapse a settled-state PR group once it reaches this many entries.
  static let pullRequestCollapseThreshold = 3

  let primaryReferences: [SessionReference]
  let collapsedMergedPullRequests: [SessionReference]
  let collapsedClosedPullRequests: [SessionReference]

  init(
    references: [SessionReference],
    collapsePullRequests: Bool,
    threshold: Int = Self.pullRequestCollapseThreshold
  ) {
    guard collapsePullRequests else {
      primaryReferences = references
      collapsedMergedPullRequests = []
      collapsedClosedPullRequests = []
      return
    }

    let merged = references.filter { $0.isPullRequest(in: .merged) }
    let closed = references.filter { $0.isPullRequest(in: .closed) }
    let collapseMerged = merged.count >= threshold
    let collapseClosed = closed.count >= threshold

    collapsedMergedPullRequests = collapseMerged ? merged : []
    collapsedClosedPullRequests = collapseClosed ? closed : []
    primaryReferences = references.filter { reference in
      if collapseMerged, reference.isPullRequest(in: .merged) { return false }
      if collapseClosed, reference.isPullRequest(in: .closed) { return false }
      return true
    }
  }

  /// The PR surfaced in the collapsed stack chip's label. An open PR is the
  /// work in flight, so it wins over settled ones; drafts come next. With
  /// only settled PRs the newest mention beats the oldest — `references`
  /// keeps insertion order, so `first` would pin the chip to a long-merged
  /// PR forever.
  nonisolated static func featuredPullRequest(in references: [SessionReference]) -> SessionReference? {
    references.first { $0.isPullRequest(in: .open) }
      ?? references.first { $0.isPullRequest(in: .draft) }
      ?? references.last
  }
}

private extension SessionReference {
  nonisolated func isPullRequest(in state: PRState) -> Bool {
    guard case .pullRequest(_, _, _, let prState, _) = self else { return false }
    return prState == state
  }
}

private struct ReferenceStackChip: View {
  enum Kind {
    case pullRequests
    case tickets

    var title: String {
      switch self {
      case .pullRequests: return "Pull requests"
      case .tickets: return "Other tickets"
      }
    }

    var systemImage: String {
      switch self {
      case .pullRequests: return "rectangle.stack.fill"
      case .tickets: return "tag.fill"
      }
    }
  }

  let kind: Kind
  let references: [SessionReference]
  let linearOrgSlug: String
  var onPopoverOpened: (() -> Void)? = nil
  /// Unlink a wrongly-associated reference. Nil hides the affordance.
  var onRemoveReference: ((SessionReference) -> Void)? = nil
  /// Latest checks/Greptile snapshot per PR reference (dedupeKey). Empty
  /// hides the CI/score indicators on the popover rows.
  var prReferenceSnapshots: [String: PullRequestSnapshot] = [:]

  @State private var isPopoverShown: Bool = false
  @State private var isMergedPullRequestsExpanded: Bool = false
  @State private var isClosedPullRequestsExpanded: Bool = false

  var body: some View {
    Button {
      isPopoverShown.toggle()
      if isPopoverShown {
        onPopoverOpened?()
      }
    } label: {
      HStack(spacing: 4) {
        stackGlyph
        Text(chipText)
          .font(.caption2.weight(.medium))
          .lineLimit(1)
      }
      .foregroundStyle(.primary.opacity(0.85))
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(tint.opacity(0.15))
      .clipShape(Capsule())
    }
    .buttonStyle(.plain)
    .help(helpText)
    .popover(isPresented: $isPopoverShown, arrowEdge: .bottom) {
      popoverContent
    }
  }

  private var stackGlyph: some View {
    ZStack {
      ForEach(0..<min(references.count, 3), id: \.self) { index in
        RoundedRectangle(cornerRadius: 2, style: .continuous)
          .strokeBorder(tint.opacity(0.75), lineWidth: 1)
          .background(
            RoundedRectangle(cornerRadius: 2, style: .continuous)
              .fill(tint.opacity(0.08))
          )
          .frame(width: 10, height: 8)
          .offset(x: CGFloat(index) * 2, y: CGFloat(index) * -1)
      }
    }
    .frame(width: 16, height: 11)
  }

  private var chipText: String {
    switch kind {
    case .pullRequests:
      guard
        case .pullRequest(_, _, let number, _, _) = ReferenceStackPopoverPresentation
          .featuredPullRequest(in: references)
      else {
        return "\(references.count) PRs"
      }
      return "#\(number) +\(references.count - 1)"
    case .tickets:
      return "+\(references.count)"
    }
  }

  private var helpText: String {
    switch kind {
    case .pullRequests:
      return "Show \(references.count) pull requests"
    case .tickets:
      let noun = references.count == 1 ? "ticket" : "tickets"
      return "Show \(references.count) more \(noun)"
    }
  }

  private var tint: Color {
    switch kind {
    case .tickets:
      return .blue
    case .pullRequests:
      let states = references.compactMap { ref -> PRState? in
        if case .pullRequest(_, _, _, let state, _) = ref { return state }
        return nil
      }
      // Open PRs signal active work, so green wins over stale closed/draft/merged refs.
      if states.contains(.open) { return .green }
      if states.contains(.closed) { return .red }
      if states.contains(.draft) { return .gray }
      if !states.isEmpty, states.allSatisfy({ $0 == .merged }) { return .purple }
      return .secondary
    }
  }

  private var popoverPresentation: ReferenceStackPopoverPresentation {
    ReferenceStackPopoverPresentation(
      references: references,
      collapsePullRequests: kind == .pullRequests
    )
  }

  private var popoverContent: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(kind.title, systemImage: kind.systemImage)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 4) {
        ForEach(popoverPresentation.primaryReferences, id: \.dedupeKey) { reference in
          referenceRow(reference)
        }
        if !popoverPresentation.collapsedMergedPullRequests.isEmpty {
          collapsedPullRequestsSection(
            state: .merged,
            references: popoverPresentation.collapsedMergedPullRequests,
            isExpanded: $isMergedPullRequestsExpanded
          )
        }
        if !popoverPresentation.collapsedClosedPullRequests.isEmpty {
          collapsedPullRequestsSection(
            state: .closed,
            references: popoverPresentation.collapsedClosedPullRequests,
            isExpanded: $isClosedPullRequestsExpanded
          )
        }
      }
    }
    .padding(12)
    .frame(minWidth: 220, maxWidth: 420, alignment: .leading)
  }

  @ViewBuilder
  private func collapsedPullRequestsSection(
    state: PRState,
    references: [SessionReference],
    isExpanded: Binding<Bool>
  ) -> some View {
    settledPullRequestsDisclosureRow(state: state, count: references.count, isExpanded: isExpanded)
    if isExpanded.wrappedValue {
      ForEach(references, id: \.dedupeKey) { reference in
        referenceRow(reference)
          .padding(.leading, 18)
      }
    }
  }

  private func settledPullRequestsDisclosureRow(
    state: PRState,
    count: Int,
    isExpanded: Binding<Bool>
  ) -> some View {
    let label = state == .merged ? "merged" : "closed"
    return Button {
      isExpanded.wrappedValue.toggle()
    } label: {
      HStack(spacing: 8) {
        Image(systemName: state.systemImage)
          .font(.caption)
          .foregroundStyle(prStateColor(state))
          .frame(width: 14)
        VStack(alignment: .leading, spacing: 1) {
          Text("\(count) \(label) pull requests")
            .font(.caption.weight(.medium))
            .lineLimit(1)
          Text(isExpanded.wrappedValue ? "Hide \(label) PRs" : "Show \(label) PRs")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer(minLength: 12)
        Image(systemName: "chevron.right")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.tertiary)
          .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
      }
      .contentShape(Rectangle())
      .padding(.vertical, 4)
    }
    .buttonStyle(.plain)
    .help("\(isExpanded.wrappedValue ? "Hide" : "Show") \(count) \(label) pull requests")
  }

  private func referenceRow(_ reference: SessionReference) -> some View {
    Button {
      open(reference)
    } label: {
      HStack(spacing: 8) {
        Image(systemName: rowSystemImage(for: reference))
          .font(.caption)
          .foregroundStyle(rowTint(for: reference))
          .frame(width: 14)
        VStack(alignment: .leading, spacing: 1) {
          Text(rowTitle(for: reference))
            .font(.caption.weight(.medium))
            .lineLimit(1)
          Text(rowSubtitle(for: reference))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            // Middle truncation keeps both the repo's tail and the PR state
            // visible when owner/repo is long.
            .truncationMode(.middle)
        }
        Spacer(minLength: 12)
        if case .pullRequest = reference,
          let snapshot = prReferenceSnapshots[reference.dedupeKey]
        {
          PRChecksSummaryText(checks: snapshot.statusChecks)
          GreptileScoreBadge(score: snapshot.greptileScore)
        }
        Image(systemName: "arrow.up.forward")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
      .contentShape(Rectangle())
      .padding(.vertical, 4)
    }
    .buttonStyle(.plain)
    .help(rowHelp(for: reference))
    .contextMenu {
      if let onRemoveReference {
        Button(role: .destructive) {
          onRemoveReference(reference)
          isPopoverShown = false
        } label: {
          Label("Remove link", systemImage: "link.badge.minus")
        }
      }
    }
  }

  private func open(_ reference: SessionReference) {
    guard let url = reference.url(linearOrgSlug: linearOrgSlug) else { return }
    NSWorkspace.shared.open(url)
    isPopoverShown = false
  }

  private func rowSystemImage(for reference: SessionReference) -> String {
    switch reference {
    case .ticket:
      return "tag.fill"
    case .pullRequest:
      return "number.circle"
    }
  }

  private func rowTint(for reference: SessionReference) -> Color {
    switch reference {
    case .ticket:
      return .blue
    case .pullRequest(_, _, _, let state, _):
      guard let state else { return .secondary }
      return prStateColor(state)
    }
  }

  /// Row headline: the id and the work-item title are what the user scans
  /// for, so they get the full line width. Repo coordinates move to the
  /// subtitle where truncation is harmless.
  private func rowTitle(for reference: SessionReference) -> String {
    switch reference {
    case .ticket(let id):
      return id
    case .pullRequest(_, _, let number, _, let title):
      guard let title, !title.isEmpty else { return "#\(number)" }
      return "#\(number) \(title)"
    }
  }

  private func rowSubtitle(for reference: SessionReference) -> String {
    switch reference {
    case .ticket:
      return linearOrgSlug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? "Linear desktop app"
        : "Linear issue"
    case .pullRequest(let owner, let repo, _, let state, _):
      return "\(owner)/\(repo) · \((state?.rawValue ?? "loading…").capitalized)"
    }
  }

  private func rowHelp(for reference: SessionReference) -> String {
    switch reference {
    case .ticket(let id):
      return linearOrgSlug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? "Open \(id) in the Linear desktop app"
        : "Open \(id) in Linear"
    case .pullRequest(let owner, let repo, let number, let state, let title):
      let stateLabel = state?.rawValue ?? "loading…"
      let statusSuffix = prReferenceSnapshots[reference.dedupeKey]?.statusHelpSuffix ?? ""
      let titleSuffix = (title?.isEmpty ?? true) ? "" : " — \(title ?? "")"
      return "Open \(owner)/\(repo) #\(number) (\(stateLabel)\(statusSuffix))\(titleSuffix) on GitHub"
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
      .pullRequest(
        owner: "foo", repo: "bar", number: 42, state: .open,
        title: "Refactor the auth module to use async/await"
      ),
      .pullRequest(owner: "foo", repo: "bar", number: 43, state: .draft, title: nil),
    ]
  )
  return VStack {
    SessionCardView(
      session: session,
      repositoryName: "my-repo",
      status: .inProgress,
      onTap: {},
      onRemove: {},
      onTogglePriority: {},
      prReferenceSnapshots: [
        "pr:foo/bar#42": PullRequestSnapshot(
          state: .open,
          title: "Refactor the auth module to use async/await",
          statusChecks: [
            GithubPullRequestStatusCheck(name: "Unit Tests", status: "COMPLETED", conclusion: "FAILURE"),
            GithubPullRequestStatusCheck(name: "Lint", status: "COMPLETED", conclusion: "SUCCESS"),
          ],
          greptileScore: 4
        ),
      ]
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
