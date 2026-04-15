import Foundation
import Observation
import Sharing

private let terminalLogger = SupaLogger("Terminal")

@MainActor
@Observable
final class WorktreeTerminalManager {
  private let runtime: GhosttyRuntime
  private(set) var socketServer: AgentHookSocketServer?
  private var states: [Worktree.ID: WorktreeTerminalState] = [:]
  /// Supacool-only. Tab IDs whose agent has emitted a `Notification` hook
  /// event since its last busy transition — i.e. the agent paused to ask
  /// the user something (permission prompt, clarification, etc.). Cleared
  /// on any busy-flag change for the tab. Observed by the Matrix Board
  /// classifier to flip cards to an "Awaiting Input" status.
  private var awaitingInputTabs: Set<UUID> = []
  private var notificationsEnabled = true
  private var lastNotificationIndicatorCount: Int?
  private var eventContinuation: AsyncStream<TerminalClient.Event>.Continuation?
  private var pendingEvents: [TerminalClient.Event] = []
  @ObservationIgnored
  @Shared(.agentSessions) private var agentSessions: [AgentSession]
  var selectedWorktreeID: Worktree.ID?
  var saveLayoutSnapshot: ((Worktree.ID, TerminalLayoutSnapshot?) -> Void)?
  var loadLayoutSnapshot: ((Worktree.ID) -> TerminalLayoutSnapshot?)?

  init(runtime: GhosttyRuntime, socketServer: AgentHookSocketServer? = nil) {
    self.runtime = runtime
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
    server.onBusy = { [weak self] worktreeID, tabID, surfaceID, active in
      let decoded = worktreeID.removingPercentEncoding ?? worktreeID
      terminalLogger.debug(
        "Hook busy: worktree=\(decoded) tab=\(tabID) surface=\(surfaceID) active=\(active)"
      )
      guard let state = self?.states[decoded] else {
        terminalLogger.debug("Dropped busy update for unknown worktree \(decoded)")
        return
      }
      // Any busy transition (resumed or finished) supersedes a prior
      // "awaiting input" signal for this tab.
      self?.awaitingInputTabs.remove(tabID)
      state.setAgentBusy(
        surfaceID: surfaceID,
        tabID: TerminalTabID(rawValue: tabID),
        active: active
      )
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
        self?.awaitingInputTabs.insert(tabID)
      }
    }
  }

  /// Decide whether a `Notification` hook event represents the agent actually
  /// blocking on user input (permission prompt, idle reminder) versus an
  /// informational ping that doesn't pause work.
  ///
  /// Claude Code fires `Notification` hooks for both. The blocking ones use a
  /// short, stable set of message prefixes; everything else (custom user
  /// notifications, status pings) keeps the card in its current state.
  /// Codex doesn't yet emit a clean signal here — preserve the legacy
  /// "any Notification event" behavior for it until we audit its payloads.
  nonisolated static func isAwaitingInputSignal(_ notification: AgentHookNotification) -> Bool {
    guard notification.event == "Notification" else { return false }
    if notification.agent.lowercased().contains("claude") {
      let body = notification.body ?? ""
      let blockingPrefixes = [
        "Claude needs your permission",
        "Claude is waiting for your input",
      ]
      return blockingPrefixes.contains(where: { body.hasPrefix($0) })
    }
    return true
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
  /// prompt, clarification). Set by a `Notification` hook event and cleared
  /// on the next busy-flag change for the tab. Requires the Notification
  /// hook to be installed (Settings → Coding Agents → Notifications).
  func isAwaitingInput(worktreeID: Worktree.ID, tabID: TerminalTabID) -> Bool {
    awaitingInputTabs.contains(tabID.rawValue)
  }

  /// Whether the session's tab still exists in any terminal state — false
  /// means the session is "detached" (PTY gone, e.g. after a relaunch).
  /// Supacool-specific; distinct from the existing `hasTab(tabID:)` which
  /// checks the currently-selected worktree only.
  func sessionTabExists(worktreeID: Worktree.ID, tabID: TerminalTabID) -> Bool {
    states[worktreeID]?.containsTabTree(tabID) ?? false
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
    case .createTab, .createTabWithInput, .ensureInitialTab, .stopRunScript, .runBlockingScript,
      .closeFocusedTab, .closeFocusedSurface, .performBindingAction, .selectTab, .focusSurface,
      .splitSurface, .destroyTab, .destroySurface, .prune, .setNotificationsEnabled,
      .setSelectedWorktreeID, .refreshTabBarVisibility:
      return false
    }
    return true
  }

  private func handleBindingActionCommand(_ command: TerminalClient.Command) -> Bool {
    switch command {
    case .performBindingAction(let worktree, let action):
      state(for: worktree).performBindingActionOnFocusedSurface(action)
    case .createTab, .createTabWithInput, .ensureInitialTab, .stopRunScript, .runBlockingScript,
      .closeFocusedTab, .closeFocusedSurface, .startSearch, .searchSelection, .navigateSearchNext,
      .navigateSearchPrevious, .endSearch, .selectTab, .focusSurface, .splitSurface, .destroyTab,
      .destroySurface, .prune, .setNotificationsEnabled, .setSelectedWorktreeID,
      .refreshTabBarVisibility:
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
    case .createTab, .createTabWithInput, .ensureInitialTab, .stopRunScript, .runBlockingScript,
      .closeFocusedTab, .closeFocusedSurface, .performBindingAction, .startSearch, .searchSelection,
      .navigateSearchNext, .navigateSearchPrevious, .endSearch, .selectTab, .focusSurface,
      .splitSurface, .destroyTab, .destroySurface:
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
