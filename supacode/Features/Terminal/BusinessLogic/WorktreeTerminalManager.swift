import Darwin
import Foundation
import Observation
import Sharing
import SwiftUI

private let terminalLogger = SupaLogger("Terminal")
private let awaitingInputTTLDefault: Duration = .seconds(8)
/// How long an `awaitingInput` signal must stay active before the chip
/// is actually shown. Wider than the off-debounce so Codex's
/// `PermissionRequest → PreToolUse` auto-approve round-trips (~200–500ms)
/// don't produce a visible blink between "In Progress" and "Wants Input".
private let awaitingInputTransitionOnDebounceDefault: Duration = .milliseconds(750)
/// Mirror debounce for turning the chip off. Kept tight so the card
/// responds quickly when the user actually answers a prompt.
private let awaitingInputTransitionOffDebounceDefault: Duration = .milliseconds(250)
private let awaitingInputActivityPollIntervalDefault: Duration = .seconds(1)
private let awaitingInputFingerprintLineCount = 12
private let awaitingInputPromptDetectionStableSamples = 2
private let agentPIDSweepIntervalDefault: Duration = .seconds(30)

private let defaultIsProcessAlive: @Sendable (Int32) -> Bool = { pid in
  // `kill(pid, 0)` returns 0 when the process exists (signal-less ping).
  // ESRCH → process gone. EPERM → exists but we can't signal it; still alive.
  if kill(pid, 0) == 0 { return true }
  return errno != ESRCH
}

@MainActor
@Observable
final class WorktreeTerminalManager {
  private struct AwaitingInputTracker {
    let worktreeID: Worktree.ID
    var rawActive = false
    var presented = false
    var lastScreenFingerprint: String?
  }

  private struct AwaitingInputPromptCandidate {
    let worktreeID: Worktree.ID
    var fingerprint: String
    var stableSampleCount = 1
  }

  /// Supacool-only. Per-tab registration of the agent process PID so a
  /// background sweep can clear stale busy/awaiting state if the agent
  /// crashes (SIGKILL, OOM) before a clean `Stop`/`SessionEnd` hook fires.
  private struct AgentPIDRegistration {
    let worktreeID: Worktree.ID
    let surfaceID: UUID
    let pid: Int32
  }

  private let runtime: GhosttyRuntime
  private let sleep: @Sendable (Duration) async throws -> Void
  private let awaitingInputTTL: Duration
  private let awaitingInputTransitionOnDebounce: Duration
  private let awaitingInputTransitionOffDebounce: Duration
  private let awaitingInputActivityPollInterval: Duration
  private let agentPIDSweepInterval: Duration
  private let isProcessAlive: @Sendable (Int32) -> Bool
  private let readScreenContentsOverride: ((Worktree.ID, TerminalTabID) -> String?)?
  private(set) var socketServer: AgentHookSocketServer?
  private var states: [Worktree.ID: WorktreeTerminalState] = [:]
  /// Supacool-only. Per-tab awaiting-input tracking. The hook signal is
  /// treated as a soft lease: it expires unless reaffirmed, and any resumed
  /// terminal output clears it after a short stabilization window.
  private var awaitingInputByTab: [UUID: AwaitingInputTracker] = [:]
  private var awaitingInputExpiryTasks: [UUID: Task<Void, Never>] = [:]
  private var awaitingInputDebounceTasks: [UUID: Task<Void, Never>] = [:]
  private var awaitingInputActivityTasks: [UUID: Task<Void, Never>] = [:]
  private var awaitingInputPromptCandidates: [UUID: AwaitingInputPromptCandidate] = [:]
  private var awaitingInputPromptScanTask: Task<Void, Never>?
  private var awaitingInputPromptScanTickCount: Int = 0
  private var agentPIDByTab: [UUID: AgentPIDRegistration] = [:]
  private var notificationsEnabled = true
  private var lastNotificationIndicatorCount: Int?
  private var eventContinuation: AsyncStream<TerminalClient.Event>.Continuation?
  private var pendingEvents: [TerminalClient.Event] = []
  @ObservationIgnored
  @Shared(.agentSessions) private var agentSessions: [AgentSession]
  var selectedWorktreeID: Worktree.ID?
  var saveLayoutSnapshot: ((Worktree.ID, TerminalLayoutSnapshot?) -> Void)?
  var loadLayoutSnapshot: ((Worktree.ID) -> TerminalLayoutSnapshot?)?

  init<C: Clock<Duration>>(
    runtime: GhosttyRuntime,
    socketServer: AgentHookSocketServer? = nil,
    awaitingInputTTL: Duration = awaitingInputTTLDefault,
    awaitingInputTransitionOnDebounce: Duration = awaitingInputTransitionOnDebounceDefault,
    awaitingInputTransitionOffDebounce: Duration = awaitingInputTransitionOffDebounceDefault,
    awaitingInputActivityPollInterval: Duration = awaitingInputActivityPollIntervalDefault,
    agentPIDSweepInterval: Duration = agentPIDSweepIntervalDefault,
    isProcessAlive: @escaping @Sendable (Int32) -> Bool = defaultIsProcessAlive,
    clock: C = ContinuousClock(),
    readScreenContents: ((Worktree.ID, TerminalTabID) -> String?)? = nil
  ) {
    self.runtime = runtime
    self.awaitingInputTTL = awaitingInputTTL
    self.awaitingInputTransitionOnDebounce = awaitingInputTransitionOnDebounce
    self.awaitingInputTransitionOffDebounce = awaitingInputTransitionOffDebounce
    self.awaitingInputActivityPollInterval = awaitingInputActivityPollInterval
    self.agentPIDSweepInterval = agentPIDSweepInterval
    self.isProcessAlive = isProcessAlive
    self.sleep = { duration in
      try await clock.sleep(for: duration)
    }
    self.readScreenContentsOverride = readScreenContents
    startAwaitingInputPromptScreenScanning()
    let resolvedServer = socketServer ?? AgentHookSocketServer()
    guard resolvedServer.socketPath != nil else {
      self.socketServer = nil
      terminalLogger.warning("Agent hook socket server unavailable")
      return
    }
    self.socketServer = resolvedServer
    configureSocketServer(resolvedServer)
  }

  private func configureSocketServer(_ server: AgentHookSocketServer) {
    server.onBusy = { [weak self] worktreeID, tabID, surfaceID, active, pid in
      let decoded = worktreeID.removingPercentEncoding ?? worktreeID
      terminalLogger.debug(
        "Hook busy: worktree=\(decoded) tab=\(tabID) surface=\(surfaceID) "
          + "active=\(active) pid=\(pid.map(String.init) ?? "nil")"
      )
      guard let state = self?.states[decoded] else {
        terminalLogger.debug("Dropped busy update for unknown worktree \(decoded)")
        return
      }
      // Register / unregister the agent PID so the 30s sweep can clear
      // stale busy state if the agent crashes before a clean hook fires.
      // Pre-upgrade hooks send pid=nil; don't disturb existing tracking.
      if let pid {
        if active {
          self?.agentPIDByTab[tabID] = AgentPIDRegistration(
            worktreeID: decoded,
            surfaceID: surfaceID,
            pid: pid
          )
        } else {
          self?.agentPIDByTab.removeValue(forKey: tabID)
        }
      }
      // Any busy transition (resumed or finished) supersedes a prior
      // "awaiting input" signal for this tab.
      self?.clearAwaitingInput(tabID: tabID)
      state.setAgentBusy(
        surfaceID: surfaceID,
        tabID: TerminalTabID(rawValue: tabID),
        active: active
      )
      // Supacool transcript: when the agent reports going idle, snapshot
      // the full surface (visible + scrollback) into the per-session
      // transcript file. The recorder dedupes against its last snapshot,
      // so this is safe to call on every idle hook.
      if !active {
        let wrappedTabID = TerminalTabID(rawValue: tabID)
        if let fullText = state.readScreenContents(tabID: wrappedTabID, scope: .surface),
          !fullText.isEmpty
        {
          TranscriptRecorder.shared.snapshotOutput(tabID: wrappedTabID, fullText: fullText)
        }
      }
    }
    server.onNotification = { [weak self] worktreeID, tabID, surfaceID, notification in
      let decoded = worktreeID.removingPercentEncoding ?? worktreeID
      terminalLogger.debug(
        "Hook notification: worktree=\(decoded) tab=\(tabID) agent=\(notification.agent) "
          + "event=\(notification.event) body=\(notification.body ?? "<nil>")"
      )
      guard let state = self?.states[decoded] else {
        terminalLogger.debug("Dropped hook notification for unknown worktree \(decoded)")
        return
      }
      let title = notification.title ?? notification.agent
      let body = notification.body ?? ""
      state.appendHookNotification(title: title, body: body, surfaceID: surfaceID)
      self?.captureAgentNativeSessionID(tabID: tabID, notification: notification)
      if Self.isAwaitingInputSignal(notification) {
        self?.markAwaitingInputSignal(worktreeID: decoded, tabID: tabID)
      }
    }
  }

  /// Decide whether a hook event represents the agent actually blocking
  /// on user input (permission prompt, idle reminder) versus an
  /// informational ping that doesn't pause work.
  ///
  /// Claude Code fires `Notification` hooks for both blocking and
  /// informational cases; the blocking ones use a short, stable set of
  /// message prefixes. Codex fires a dedicated `PermissionRequest`
  /// event for the blocking case, which is the clean signal we want.
  nonisolated static func isAwaitingInputSignal(_ notification: AgentHookNotification) -> Bool {
    let agent = notification.agent.lowercased()
    if agent.contains("claude") {
      guard notification.event == "Notification" else { return false }
      let body = notification.body ?? ""
      let blockingPrefixes = [
        "Claude needs your permission",
        "Claude is waiting for your input",
      ]
      return blockingPrefixes.contains(where: { body.hasPrefix($0) })
    }
    if agent.contains("codex") {
      // PermissionRequest is the precise signal; keep the legacy
      // wildcard on Notification for forward compatibility in case
      // Codex grows one.
      return notification.event == "PermissionRequest"
        || notification.event == "Notification"
    }
    // Unknown agents: preserve the legacy "any Notification event" heuristic.
    return notification.event == "Notification"
  }

  /// Screen-based fallback for hook misses. This only matches the inline
  /// approval UI used by Claude's edit / permission prompts, and still
  /// requires repeated identical samples before the tab is promoted.
  nonisolated static func isAwaitingInputPromptScreen(_ screen: String) -> Bool {
    let lines = screen
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map {
        $0
          .trimmingCharacters(in: .whitespacesAndNewlines)
          .lowercased()
      }
      .filter { !$0.isEmpty }

    guard !lines.isEmpty else { return false }

    let normalized = lines.joined(separator: "\n")
    let hasPrimaryPromptLead =
      normalized.contains("do you want to make this edit")
      || normalized.contains("claude needs your permission")
      || normalized.contains("do you want to allow claude")
      || normalized.contains("allow claude to edit its own settings")
    let hasApprovalOptions =
      lines.contains { $0 == "1. yes" || $0.hasPrefix("1. yes,") || $0.hasPrefix("1. allow") }
      && lines.contains {
        $0 == "2. yes"
          || $0.hasPrefix("2. yes,")
          || $0.hasPrefix("2. allow")
          || $0 == "2. no"
      }
    let hasDismissOption = lines.contains { $0 == "3. no" || $0.hasPrefix("3. no,") }
    let hasPromptFooter =
      normalized.contains("esc to cancel")
      && (normalized.contains("tab to amend") || normalized.contains("enter to confirm"))

    return hasPrimaryPromptLead && hasApprovalOptions && hasDismissOption && hasPromptFooter
  }

  /// Persists the agent-native session identifier from a hook payload onto
  /// the matching `AgentSession` (by tabID). Silently no-ops when no session
  /// exists for the tab yet, or when the payload carried no session id.
  private func captureAgentNativeSessionID(
    tabID: UUID,
    notification: AgentHookNotification
  ) {
    guard let sessionID = notification.sessionID, !sessionID.isEmpty else { return }
    $agentSessions.withLock { sessions in
      guard let index = sessions.firstIndex(where: { $0.id == tabID }) else { return }
      guard sessions[index].agentNativeSessionID != sessionID else { return }
      sessions[index].agentNativeSessionID = sessionID
      sessions[index].lastActivityAt = Date()
      terminalLogger.info(
        "Captured \(notification.agent) session id \(sessionID) for tab \(tabID)"
      )
    }
  }

  // MARK: - Supacool Matrix Board queries

  /// Whether the Ghostty tab with the given ID is currently busy (agent
  /// active or long-running command in progress). Reads flow through the
  /// @Observable tracking so callers re-render when state changes.
  func isAgentBusy(worktreeID: Worktree.ID, tabID: TerminalTabID) -> Bool {
    states[worktreeID]?.isTabBusy(tabID) ?? false
  }

  /// Whether the agent in this tab is paused on user input (permission
  /// prompt, clarification). Set by a `Notification` hook event, held on a
  /// short lease, and cleared when terminal activity resumes or the lease
  /// expires. Hook signals are preferred, but a narrow screen-pattern
  /// fallback can also promote known approval prompts when a hook is missed.
  func isAwaitingInput(worktreeID: Worktree.ID, tabID: TerminalTabID) -> Bool {
    awaitingInputByTab[tabID.rawValue]?.presented == true
  }

  /// Whether the session's tab still exists in any terminal state — false
  /// means the session is "detached" (PTY gone, e.g. after a relaunch).
  /// Supacool-specific; distinct from the existing `hasTab(tabID:)` which
  /// checks the currently-selected worktree only.
  func sessionTabExists(worktreeID: Worktree.ID, tabID: TerminalTabID) -> Bool {
    states[worktreeID]?.containsTabTree(tabID) ?? false
  }

  /// Fire a Ghostty binding action against the focused surface in the
  /// given worktree's state. Used by the Supacool "Recent prompts"
  /// popover to pre-populate the ⌘F search overlay via
  /// `performBindingAction("search:<needle>")`.
  @discardableResult
  func performBindingAction(worktreeID: Worktree.ID, action: String) -> Bool {
    states[worktreeID]?.performBindingActionOnFocusedSurface(action) ?? false
  }

  func handleCommand(_ command: TerminalClient.Command) {
    if handleTabCommand(command) {
      return
    }
    if handleBindingActionCommand(command) {
      return
    }
    if handleSearchCommand(command) {
      return
    }
    handleManagementCommand(command)
  }

  // swiftlint:disable:next cyclomatic_complexity
  private func handleTabCommand(_ command: TerminalClient.Command) -> Bool {
    switch command {
    case .createTab(let worktree, let runSetupScriptIfNew, let id):
      Task { createTabAsync(in: worktree, runSetupScriptIfNew: runSetupScriptIfNew, tabID: id) }
    case .createTabWithInput(let worktree, let input, let runSetupScriptIfNew, let id):
      Task {
        createTabAsync(in: worktree, runSetupScriptIfNew: runSetupScriptIfNew, initialInput: input, tabID: id)
      }
    case .createRemoteTab(let worktree, let command, let id):
      // Supacool: bypass setup-script / default-shell plumbing entirely
      // — the supplied command is the full ssh invocation.
      let state = state(for: worktree) { false }
      _ = state.createTab(tabID: id, command: command)
    case .ensureInitialTab(let worktree, let runSetupScriptIfNew, let focusing):
      let state = state(for: worktree) { runSetupScriptIfNew }
      state.ensureInitialTab(focusing: focusing)
    case .stopRunScript(let worktree):
      _ = state(for: worktree).stopRunScript()
    case .runBlockingScript(let worktree, let kind, let script):
      _ = state(for: worktree).runBlockingScript(kind: kind, script)
    case .closeFocusedTab(let worktree):
      _ = closeFocusedTab(in: worktree)
    case .closeFocusedSurface(let worktree):
      _ = closeFocusedSurface(in: worktree)
    case .selectTab(let worktree, let tabID):
      state(for: worktree).selectTab(tabID)
    case .focusSurface(let worktree, let tabID, let surfaceID, let input):
      let terminal = state(for: worktree)
      terminal.selectTab(tabID)
      guard terminal.focusSurface(id: surfaceID) else {
        terminalLogger.warning("focusSurface: surface \(surfaceID) not found in worktree \(worktree.id).")
        break
      }
      if let input, !input.isEmpty {
        terminal.focusAndInsertText(input + "\r")
      }
    case .splitSurface(let worktree, let tabID, let surfaceID, let direction, let input, let id):
      let terminal = state(for: worktree)
      terminal.selectTab(tabID)
      let ghosttyDirection: GhosttySplitAction.NewDirection = direction == .vertical ? .down : .right
      let splitSucceeded = terminal.performSplitAction(
        .newSplit(direction: ghosttyDirection), for: surfaceID, newSurfaceID: id)
      guard splitSucceeded else {
        terminalLogger.warning("splitSurface: failed for surface \(surfaceID) in worktree \(worktree.id).")
        break
      }
      guard let input, !input.isEmpty else { break }
      terminal.focusAndInsertText(input + "\r")
    case .destroyTab(let worktree, let tabID):
      let terminal = state(for: worktree)
      guard terminal.tabManager.tabs.contains(where: { $0.id == tabID }) else {
        terminalLogger.warning("destroyTab: tab \(tabID.rawValue) not found in worktree \(worktree.id).")
        break
      }
      terminal.closeTab(tabID)
    case .destroySurface(let worktree, let tabID, let surfaceID):
      let terminal = state(for: worktree)
      terminal.selectTab(tabID)
      if !terminal.closeSurface(id: surfaceID) {
        terminalLogger.warning("destroySurface: surface \(surfaceID) not found in worktree \(worktree.id).")
      }
    case .sendText(let worktreeID, let tabID, let text):
      states[worktreeID]?.sendText(to: tabID, text: text)
    default:
      return false
    }
    return true
  }

  private func handleSearchCommand(_ command: TerminalClient.Command) -> Bool {
    switch command {
    case .startSearch(let worktree):
      state(for: worktree).performBindingActionOnFocusedSurface("start_search")
    case .searchSelection(let worktree):
      state(for: worktree).performBindingActionOnFocusedSurface("search_selection")
    case .navigateSearchNext(let worktree):
      state(for: worktree).navigateSearchOnFocusedSurface(.next)
    case .navigateSearchPrevious(let worktree):
      state(for: worktree).navigateSearchOnFocusedSurface(.previous)
    case .endSearch(let worktree):
      state(for: worktree).performBindingActionOnFocusedSurface("end_search")
    case .createTab, .createTabWithInput, .createRemoteTab, .ensureInitialTab, .stopRunScript,
      .runBlockingScript, .closeFocusedTab, .closeFocusedSurface, .performBindingAction, .selectTab,
      .focusSurface, .splitSurface, .destroyTab, .destroySurface, .prune, .setNotificationsEnabled,
      .setSelectedWorktreeID, .refreshTabBarVisibility, .sendText:
      return false
    }
    return true
  }

  private func handleBindingActionCommand(_ command: TerminalClient.Command) -> Bool {
    switch command {
    case .performBindingAction(let worktree, let action):
      state(for: worktree).performBindingActionOnFocusedSurface(action)
    case .createTab, .createTabWithInput, .createRemoteTab, .ensureInitialTab, .stopRunScript,
      .runBlockingScript, .closeFocusedTab, .closeFocusedSurface, .startSearch, .searchSelection,
      .navigateSearchNext, .navigateSearchPrevious, .endSearch, .selectTab, .focusSurface,
      .splitSurface, .destroyTab, .destroySurface, .prune, .setNotificationsEnabled,
      .setSelectedWorktreeID, .refreshTabBarVisibility, .sendText:
      return false
    }
    return true
  }

  private func handleManagementCommand(_ command: TerminalClient.Command) {
    switch command {
    case .prune(let ids):
      prune(keeping: ids)
    case .setNotificationsEnabled(let enabled):
      setNotificationsEnabled(enabled)
    case .refreshTabBarVisibility:
      for state in states.values {
        state.refreshTabBarVisibility()
      }
    case .setSelectedWorktreeID(let id):
      guard id != selectedWorktreeID else { return }
      if let previousID = selectedWorktreeID, let previousState = states[previousID] {
        previousState.setAllSurfacesOccluded()
        saveLayoutSnapshot?(previousID, previousState.captureLayoutSnapshot())
      }
      selectedWorktreeID = id
      terminalLogger.info("Selected worktree \(id ?? "nil")")
    case .createTab, .createTabWithInput, .createRemoteTab, .ensureInitialTab, .stopRunScript,
      .runBlockingScript, .closeFocusedTab, .closeFocusedSurface, .performBindingAction,
      .startSearch, .searchSelection, .navigateSearchNext, .navigateSearchPrevious, .endSearch,
      .selectTab, .focusSurface, .splitSurface, .destroyTab, .destroySurface, .sendText:
      assertionFailure("Unhandled terminal command reached management handler: \(command)")
    }
  }

  func eventStream() -> AsyncStream<TerminalClient.Event> {
    eventContinuation?.finish()
    let (stream, continuation) = AsyncStream.makeStream(of: TerminalClient.Event.self)
    eventContinuation = continuation
    lastNotificationIndicatorCount = nil
    if !pendingEvents.isEmpty {
      let bufferedEvents = pendingEvents
      pendingEvents.removeAll()
      for event in bufferedEvents {
        if case .notificationIndicatorChanged = event {
          continue
        }
        continuation.yield(event)
      }
    }
    emitNotificationIndicatorCountIfNeeded()
    return stream
  }

  func state(
    for worktree: Worktree,
    runSetupScriptIfNew: () -> Bool = { false }
  ) -> WorktreeTerminalState {
    if let existing = states[worktree.id] {
      if runSetupScriptIfNew() {
        existing.enableSetupScriptIfNeeded()
      }
      // Reload snapshot if the state has no tabs (e.g., setting was just enabled).
      if existing.tabManager.tabs.isEmpty,
        existing.pendingLayoutSnapshot == nil,
        !existing.needsSetupScript()
      {
        existing.pendingLayoutSnapshot = loadLayoutSnapshot?(worktree.id)
      }
      return existing
    }
    let runSetupScript = runSetupScriptIfNew()
    let state = WorktreeTerminalState(
      runtime: runtime,
      worktree: worktree,
      runSetupScript: runSetupScript
    )
    state.socketPath = socketServer?.socketPath
    // Load saved layout snapshot for restoration (skip when a setup script is pending).
    if !runSetupScript {
      state.pendingLayoutSnapshot = loadLayoutSnapshot?(worktree.id)
    }
    state.setNotificationsEnabled(notificationsEnabled)
    state.isSelected = { [weak self] in
      self?.selectedWorktreeID == worktree.id
    }
    state.onNotificationReceived = { [weak self] title, body in
      self?.emit(.notificationReceived(worktreeID: worktree.id, title: title, body: body))
    }
    state.onNotificationIndicatorChanged = { [weak self] in
      self?.emitNotificationIndicatorCountIfNeeded()
    }
    state.onTabCreated = { [weak self] in
      self?.emit(.tabCreated(worktreeID: worktree.id))
    }
    state.onTabClosed = { [weak self] in
      self?.emit(.tabClosed(worktreeID: worktree.id))
    }
    state.onFocusChanged = { [weak self] surfaceID in
      self?.emit(.focusChanged(worktreeID: worktree.id, surfaceID: surfaceID))
    }
    state.onTaskStatusChanged = { [weak self] status in
      self?.emit(.taskStatusChanged(worktreeID: worktree.id, status: status))
    }
    state.onBlockingScriptCompleted = { [weak self] kind, exitCode, tabId in
      self?.emit(.blockingScriptCompleted(worktreeID: worktree.id, kind: kind, exitCode: exitCode, tabId: tabId))
    }
    state.onCommandPaletteToggle = { [weak self] in
      self?.emit(.commandPaletteToggleRequested(worktreeID: worktree.id))
    }
    state.onSetupScriptConsumed = { [weak self] in
      self?.emit(.setupScriptConsumed(worktreeID: worktree.id))
    }
    states[worktree.id] = state
    terminalLogger.info("Created terminal state for worktree \(worktree.id)")
    return state
  }

  private func createTabAsync(
    in worktree: Worktree,
    runSetupScriptIfNew: Bool,
    initialInput: String? = nil,
    tabID: UUID? = nil
  ) {
    let state = state(for: worktree) { runSetupScriptIfNew }
    let setupScript: String?
    if state.needsSetupScript() {
      @SharedReader(.repositorySettings(worktree.repositoryRootURL))
      var settings = RepositorySettings.default
      setupScript = settings.setupScript
    } else {
      setupScript = nil
    }
    _ = state.createTab(setupScript: setupScript, initialInput: initialInput, tabID: tabID)
  }

  @discardableResult
  func closeFocusedTab(in worktree: Worktree) -> Bool {
    let state = state(for: worktree)
    return state.closeFocusedTab()
  }

  @discardableResult
  func closeFocusedSurface(in worktree: Worktree) -> Bool {
    let state = state(for: worktree)
    return state.closeFocusedSurface()
  }

  func prune(keeping worktreeIDs: Set<Worktree.ID>) {
    var removed: [(Worktree.ID, WorktreeTerminalState)] = []
    for (id, state) in states where !worktreeIDs.contains(id) {
      removed.append((id, state))
    }
    for (id, state) in removed {
      saveLayoutSnapshot?(id, state.captureLayoutSnapshot())
      state.closeAllSurfaces()
    }
    if !removed.isEmpty {
      terminalLogger.info("Pruned \(removed.count) terminal state(s)")
    }
    states = states.filter { worktreeIDs.contains($0.key) }
    emitNotificationIndicatorCountIfNeeded()
  }

  func tabExists(worktreeID: Worktree.ID, tabID: TerminalTabID) -> Bool {
    states[worktreeID]?.hasTab(tabID) ?? false
  }

  func surfaceExists(worktreeID: Worktree.ID, tabID: TerminalTabID, surfaceID: UUID) -> Bool {
    states[worktreeID]?.hasSurface(surfaceID, in: tabID) ?? false
  }

  func readScreenContents(worktreeID: Worktree.ID, tabID: TerminalTabID) -> String? {
    states[worktreeID]?.readScreenContents(tabID: tabID)
  }

  /// Foreground PID of a session's focused surface, or nil when the
  /// tab has no live surface (not yet spawned, or already exited).
  /// Used by Supacool's per-session memory attribution.
  func foregroundPID(worktreeID: Worktree.ID, tabID: TerminalTabID) -> Int32? {
    states[worktreeID]?.foregroundPID(tabID: tabID)
  }

  func stateIfExists(for worktreeID: Worktree.ID) -> WorktreeTerminalState? {
    states[worktreeID]
  }

  func taskStatus(for worktreeID: Worktree.ID) -> WorktreeTaskStatus? {
    states[worktreeID]?.taskStatus
  }

  func isBlockingScriptRunning(kind: BlockingScriptKind, for worktreeID: Worktree.ID) -> Bool {
    states[worktreeID]?.isBlockingScriptRunning(kind: kind) == true
  }

  func setNotificationsEnabled(_ enabled: Bool) {
    notificationsEnabled = enabled
    for state in states.values {
      state.setNotificationsEnabled(enabled)
    }
    emitNotificationIndicatorCountIfNeeded()
  }

  func hasUnseenNotifications(for worktreeID: Worktree.ID) -> Bool {
    states[worktreeID]?.hasUnseenNotification == true
  }

  func saveAllLayoutSnapshots() {
    guard let saveLayoutSnapshot else {
      assertionFailure("saveLayoutSnapshot closure not configured.")
      return
    }
    for (id, state) in states {
      saveLayoutSnapshot(id, state.captureLayoutSnapshot())
    }
  }

  func surfaceBackgroundOpacity() -> Double {
    runtime.backgroundOpacity()
  }

  func unfocusedSplitOverlay() -> (fill: Color?, opacity: Double) {
    (runtime.unfocusedSplitFill(), runtime.unfocusedSplitOverlayOpacity())
  }

  private func markAwaitingInputSignal(worktreeID: Worktree.ID, tabID: UUID) {
    markAwaitingInputSignal(
      worktreeID: worktreeID,
      tabID: tabID,
      fingerprint: screenFingerprint(worktreeID: worktreeID, tabID: TerminalTabID(rawValue: tabID))
    )
  }

  private func markAwaitingInputSignal(
    worktreeID: Worktree.ID,
    tabID: UUID,
    fingerprint: String?
  ) {
    var tracker = awaitingInputByTab[tabID] ?? AwaitingInputTracker(worktreeID: worktreeID)
    tracker.rawActive = true
    tracker.lastScreenFingerprint = fingerprint
    awaitingInputByTab[tabID] = tracker
    scheduleAwaitingInputExpiry(for: tabID)
    scheduleAwaitingInputActivityPolling(for: tabID)
    scheduleAwaitingInputPresentationReconciliation(for: tabID, desiredState: true)
  }

  private func clearAwaitingInput(tabID: UUID) {
    awaitingInputExpiryTasks.removeValue(forKey: tabID)?.cancel()
    awaitingInputActivityTasks.removeValue(forKey: tabID)?.cancel()
    awaitingInputPromptCandidates.removeValue(forKey: tabID)

    guard var tracker = awaitingInputByTab[tabID] else { return }
    tracker.rawActive = false
    tracker.lastScreenFingerprint = nil

    if tracker.presented {
      awaitingInputByTab[tabID] = tracker
      scheduleAwaitingInputPresentationReconciliation(for: tabID, desiredState: false)
    } else {
      awaitingInputDebounceTasks.removeValue(forKey: tabID)?.cancel()
      awaitingInputByTab.removeValue(forKey: tabID)
    }
  }

  private func scheduleAwaitingInputExpiry(for tabID: UUID) {
    awaitingInputExpiryTasks.removeValue(forKey: tabID)?.cancel()
    let sleep = self.sleep
    let awaitingInputTTL = self.awaitingInputTTL
    awaitingInputExpiryTasks[tabID] = Task { [weak self, sleep, awaitingInputTTL] in
      do {
        try await sleep(awaitingInputTTL)
      } catch {
        return
      }
      guard let self else { return }
      await self.expireAwaitingInput(tabID: tabID)
    }
  }

  private func expireAwaitingInput(tabID: UUID) {
    awaitingInputExpiryTasks[tabID] = nil
    clearAwaitingInput(tabID: tabID)
  }

  private func scheduleAwaitingInputActivityPolling(for tabID: UUID) {
    guard awaitingInputActivityTasks[tabID] == nil else { return }
    let sleep = self.sleep
    let awaitingInputActivityPollInterval = self.awaitingInputActivityPollInterval
    awaitingInputActivityTasks[tabID] = Task { [weak self, sleep, awaitingInputActivityPollInterval] in
      while !Task.isCancelled {
        do {
          try await sleep(awaitingInputActivityPollInterval)
        } catch {
          return
        }
        guard let self else { return }
        await self.sampleAwaitingInputActivity(tabID: tabID)
      }
    }
  }

  private func sampleAwaitingInputActivity(tabID: UUID) {
    guard var tracker = awaitingInputByTab[tabID] else {
      awaitingInputActivityTasks.removeValue(forKey: tabID)?.cancel()
      return
    }
    guard tracker.rawActive else {
      awaitingInputActivityTasks.removeValue(forKey: tabID)?.cancel()
      return
    }

    let tab = TerminalTabID(rawValue: tabID)
    let newFingerprint = screenFingerprint(worktreeID: tracker.worktreeID, tabID: tab)

    if let previousFingerprint = tracker.lastScreenFingerprint,
      let newFingerprint,
      previousFingerprint != newFingerprint
    {
      tracker.lastScreenFingerprint = newFingerprint
      awaitingInputByTab[tabID] = tracker
      clearAwaitingInput(tabID: tabID)
      return
    }

    tracker.lastScreenFingerprint = newFingerprint
    awaitingInputByTab[tabID] = tracker
  }

  private func scheduleAwaitingInputPresentationReconciliation(
    for tabID: UUID,
    desiredState: Bool
  ) {
    awaitingInputDebounceTasks.removeValue(forKey: tabID)?.cancel()
    let sleep = self.sleep
    let debounce =
      desiredState
      ? awaitingInputTransitionOnDebounce
      : awaitingInputTransitionOffDebounce
    awaitingInputDebounceTasks[tabID] = Task { [weak self, sleep, debounce] in
      do {
        try await sleep(debounce)
      } catch {
        return
      }
      guard let self else { return }
      await self.commitAwaitingInputPresentation(for: tabID, desiredState: desiredState)
    }
  }

  private func startAwaitingInputPromptScreenScanning() {
    guard awaitingInputPromptScanTask == nil else { return }
    let sleep = self.sleep
    let awaitingInputActivityPollInterval = self.awaitingInputActivityPollInterval
    awaitingInputPromptScanTask = Task { [weak self, sleep, awaitingInputActivityPollInterval] in
      while !Task.isCancelled {
        do {
          try await sleep(awaitingInputActivityPollInterval)
        } catch {
          return
        }
        guard let self else { return }
        await self.sampleAwaitingInputPromptScreens()
      }
    }
  }

  private func sampleAwaitingInputPromptScreens() {
    tickAgentPIDSweepIfNeeded()
    var openTabIDs = Set<UUID>()

    for (worktreeID, state) in states {
      for tab in state.tabManager.tabs {
        let tabID = tab.id.rawValue
        openTabIDs.insert(tabID)

        guard let fingerprint = screenFingerprint(worktreeID: worktreeID, tabID: tab.id),
          Self.isAwaitingInputPromptScreen(fingerprint)
        else {
          awaitingInputPromptCandidates.removeValue(forKey: tabID)
          continue
        }

        var candidate: AwaitingInputPromptCandidate
        if var existing = awaitingInputPromptCandidates[tabID] {
          if existing.fingerprint == fingerprint {
            existing.stableSampleCount += 1
          } else {
            existing = AwaitingInputPromptCandidate(worktreeID: worktreeID, fingerprint: fingerprint)
          }
          candidate = existing
        } else {
          candidate = AwaitingInputPromptCandidate(worktreeID: worktreeID, fingerprint: fingerprint)
        }

        awaitingInputPromptCandidates[tabID] = candidate

        guard candidate.stableSampleCount >= awaitingInputPromptDetectionStableSamples else { continue }
        markAwaitingInputSignal(worktreeID: candidate.worktreeID, tabID: tabID, fingerprint: fingerprint)
      }
    }

    cleanupAwaitingInputTracking(closedTabIDs: Set(awaitingInputByTab.keys).subtracting(openTabIDs))
    awaitingInputPromptCandidates = awaitingInputPromptCandidates.filter { openTabIDs.contains($0.key) }
  }

  private func cleanupAwaitingInputTracking(closedTabIDs: Set<UUID>) {
    guard !closedTabIDs.isEmpty else { return }
    for tabID in closedTabIDs {
      awaitingInputExpiryTasks.removeValue(forKey: tabID)?.cancel()
      awaitingInputActivityTasks.removeValue(forKey: tabID)?.cancel()
      awaitingInputDebounceTasks.removeValue(forKey: tabID)?.cancel()
      awaitingInputPromptCandidates.removeValue(forKey: tabID)
      awaitingInputByTab.removeValue(forKey: tabID)
      agentPIDByTab.removeValue(forKey: tabID)
    }
  }

  // MARK: - Agent PID sweep (Supacool)

  /// Ticks the sweep counter from the 1s prompt-scan loop and runs a
  /// full `kill(pid, 0)` sweep every `agentPIDSweepInterval`. Piggy-
  /// backing on the existing timer avoids a second background Task
  /// whose mere presence was observed to destabilise TestClock-driven
  /// tests when Swift Testing runs multiple tests in parallel.
  private func tickAgentPIDSweepIfNeeded() {
    awaitingInputPromptScanTickCount &+= 1
    let ticksPerSweep = max(
      1,
      Int(agentPIDSweepInterval / awaitingInputActivityPollInterval)
    )
    guard awaitingInputPromptScanTickCount % ticksPerSweep == 0 else { return }
    sweepAgentPIDs()
  }

  /// Walks registered agent PIDs and clears busy/awaiting state for any
  /// whose process has died. Safety net for SIGKILL/OOM where no hook
  /// fires to report the transition.
  func sweepAgentPIDs() {
    guard !agentPIDByTab.isEmpty else { return }
    var dead: [(tabID: UUID, registration: AgentPIDRegistration)] = []
    for (tabID, registration) in agentPIDByTab where !isProcessAlive(registration.pid) {
      dead.append((tabID, registration))
    }
    for (tabID, registration) in dead {
      terminalLogger.info(
        "Agent PID \(registration.pid) gone; clearing tab \(tabID) busy/awaiting state"
      )
      agentPIDByTab.removeValue(forKey: tabID)
      clearAwaitingInput(tabID: tabID)
      guard let state = states[registration.worktreeID] else { continue }
      state.setAgentBusy(
        surfaceID: registration.surfaceID,
        tabID: TerminalTabID(rawValue: tabID),
        active: false
      )
    }
  }

  /// Whether an agent PID has been registered for this tab (pre-upgrade
  /// hook clients don't send a PID so this can be false even for a live
  /// agent). Exposed for tests and for the Matrix Board's sweep debug UI.
  func registeredAgentPID(tabID: UUID) -> Int32? {
    agentPIDByTab[tabID]?.pid
  }

  private func commitAwaitingInputPresentation(for tabID: UUID, desiredState: Bool) {
    awaitingInputDebounceTasks[tabID] = nil
    guard var tracker = awaitingInputByTab[tabID] else { return }
    guard tracker.rawActive == desiredState else { return }

    if tracker.presented == desiredState {
      if !tracker.rawActive {
        awaitingInputByTab.removeValue(forKey: tabID)
      }
      return
    }

    tracker.presented = desiredState
    if tracker.rawActive || tracker.presented {
      awaitingInputByTab[tabID] = tracker
    } else {
      awaitingInputByTab.removeValue(forKey: tabID)
    }
  }

  private func screenFingerprint(worktreeID: Worktree.ID, tabID: TerminalTabID) -> String? {
    let contents = readScreenContentsOverride?(worktreeID, tabID) ?? states[worktreeID]?.readScreenContents(tabID: tabID)
    let screen = contents?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let screen, !screen.isEmpty else { return nil }

    let tail = screen
      .split(separator: "\n", omittingEmptySubsequences: false)
      .suffix(awaitingInputFingerprintLineCount)
      .joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return tail.isEmpty ? nil : tail
  }

  private func emit(_ event: TerminalClient.Event) {
    guard let eventContinuation else {
      pendingEvents.append(event)
      return
    }
    eventContinuation.yield(event)
  }

  private func emitNotificationIndicatorCountIfNeeded() {
    let count = states.values.reduce(0) { count, state in
      count + (state.hasUnseenNotification ? 1 : 0)
    }
    if count != lastNotificationIndicatorCount {
      lastNotificationIndicatorCount = count
      emit(.notificationIndicatorChanged(count: count))
    }
  }
}
