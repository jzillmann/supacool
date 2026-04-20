import AppKit
import ComposableArchitecture
import SwiftUI

/// Top-level Matrix Board container. Swaps between the board grid and a
/// full-screen terminal view based on `focusedSessionID`. Since Phase 4f
/// this is the primary root view of the app.
///
/// `onAddRepository` is a callback up to the parent (ContentView) which
/// owns the file importer — the board itself doesn't know how to trigger
/// the macOS open panel.
struct BoardRootView: View {
  @Bindable var store: StoreOf<BoardFeature>
  let repositories: IdentifiedArrayOf<Repository>
  let terminalManager: WorktreeTerminalManager
  let onAddRepository: () -> Void
  let onConfigureRepositories: () -> Void

  /// The session being renamed right now (nil = alert hidden). Owned here so
  /// both the board cards and the full-screen header can trigger rename
  /// through a single code path.
  @State private var renamingSessionID: AgentSession.ID?
  @State private var renameDraft: String = ""

  /// Keyboard-nav highlight lives here (not on `BoardView`) because
  /// `BoardView` is torn down and re-created every time the user enters
  /// and exits a full-screen session — @State on BoardView would reset
  /// to the first card on re-entry. Keeping it on BoardRootView preserves
  /// "come back to the card you just left."
  @State private var highlightedSessionID: AgentSession.ID?

  /// When true, the ⌘-Tab-style session switcher overlay is visible over
  /// the full-screen terminal. Opened by `⌘⌥←/→/↑/↓` (plain ⌘+arrow is
  /// reserved for the terminal surface's own line-navigation), committed
  /// on ⌥ release (see `SessionSwitcherOverlay`).
  @State private var isSessionSwitcherPresented: Bool = false

  /// Auto-zoom back to the board the moment a submitted prompt kicks the
  /// agent from idle → busy, so the user can see the whole fleet at a
  /// glance while the agent works. Gated on
  /// `session.hasCompletedAtLeastOnce` so a session's *initial* launch
  /// doesn't bounce out.
  @AppStorage("supacool.autoZoomBackOnPrompt") private var autoZoomBackOnPrompt: Bool = true

  /// Pending auto-navigate triggered by an idle→busy transition. `destination`
  /// nil = back to board; otherwise the session to focus next. The view
  /// shows a countdown banner and commits the nav when the task completes;
  /// Esc, a fast agent reply, or any manual focus change cancels it.
  @State private var pendingExit: PendingExit?
  @State private var pendingExitTask: Task<Void, Never>?
  @State private var pendingExitEscapeMonitor: Any?
  /// Arms auto-zoom-back only after the focused session has been observed
  /// idle in-place. This prevents "open an already-busy terminal" from
  /// looking like a fresh prompt submission.
  @State private var autoZoomBackArmedSessionID: AgentSession.ID?

  /// Grace period after prompt submission before the auto-zoom-back fires.
  /// 3s feels long enough to watch the agent start without being in the way.
  private let pendingExitDelay: Duration = .seconds(3)

  private struct PendingExit: Equatable {
    let destination: AgentSession.ID?
    let startedAt: Date
  }

  var body: some View {
    currentContent
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.background)
    // Hidden per-session watchers. Live at the root so busy/awaiting-input
    // transitions still trigger the auto-observer (and persist
    // lastKnownBusy) while the user is inside a full-screen terminal.
    .background(sessionStateWatchers)
    .onChange(of: pendingExit != nil) { _, isActive in
      if isActive {
        installPendingExitEscapeMonitor()
      } else {
        removePendingExitEscapeMonitor()
      }
    }
    .onDisappear { removePendingExitEscapeMonitor() }
    // Global shortcuts available in both board and full-screen modes.
    .background(
      Button("") {
        store.send(.openNewTerminalSheet(repositories: Array(repositories)))
      }
      .keyboardShortcut("n", modifiers: .command)
      .hidden()
      .disabled(repositories.isEmpty)
    )
    // Mirror the focused session into the keyboard-nav highlight so that
    // entering a card (tap, Enter, ⌘.) updates the cursor, and the user
    // returns to that same card when they come back to the board.
    .onChange(of: store.focusedSessionID) { oldValue, newValue in
      if let newValue { highlightedSessionID = newValue }
      // Any manual focus change invalidates a queued auto-exit —
      // otherwise the countdown would commit on top of the user's own
      // navigation (⌘B, ⌘-arrow, card tap, etc.).
      if oldValue != newValue {
        cancelPendingExit()
        armAutoZoomBack(for: newValue)
      }
    }
    // Auto-zoom-back scheduling. idle → busy means the user just
    // submitted a prompt; queue a timed hand-off instead of jumping
    // immediately so they can watch the agent start and optionally
    // cancel with Esc. busy → idle during the countdown means the
    // agent finished before we left — bail and stay.
    .onChange(of: focusedSessionBusyState) { oldValue, newValue in
      guard autoZoomBackOnPrompt else { return }
      guard let focusedID = store.focusedSessionID,
        let session = store.sessions.first(where: { $0.id == focusedID })
      else {
        autoZoomBackArmedSessionID = nil
        return
      }
      if oldValue == true, newValue == false {
        cancelPendingExit()
        autoZoomBackArmedSessionID = focusedID
        return
      }
      guard oldValue == false, newValue == true else { return }
      guard autoZoomBackArmedSessionID == focusedID,
        session.hasCompletedAtLeastOnce
      else { return }
      autoZoomBackArmedSessionID = nil
      schedulePendingExit(for: focusedID)
    }
    // Sheet lives at the root so it's reachable whether you're looking at
    // the board or at a full-screen terminal.
    .sheet(
      store: store.scope(state: \.$newTerminalSheet, action: \.newTerminalSheet)
    ) { sheetStore in
      NewTerminalSheet(store: sheetStore)
    }
    .alert(
      "Rename session",
      isPresented: Binding(
        get: { renamingSessionID != nil },
        set: { if !$0 { renamingSessionID = nil } }
      ),
      presenting: renamingSessionID
    ) { id in
      TextField("Name", text: $renameDraft)
      Button("Cancel", role: .cancel) { renamingSessionID = nil }
      Button("Save") {
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
          store.send(.renameSession(id: id, newName: trimmed))
        }
        renamingSessionID = nil
      }
    }
    // Summary after `git worktree prune` runs from the repo picker.
    // Extracted into a ViewModifier to keep the SwiftUI type-checker
    // happy — the body's modifier chain is already long.
    .modifier(PruneAlertModifier(store: store))
  }

  @ViewBuilder
  private var currentContent: some View {
    if let focusedID = store.focusedSessionID,
      let session = store.sessions.first(where: { $0.id == focusedID })
    {
      FullScreenTerminalView(
        session: session,
        repositories: repositories,
        terminalManager: terminalManager,
        onBackToBoard: { store.send(.focusSession(id: nil)) },
        onNewTerminal: {
          store.send(.openNewTerminalSheet(repositories: Array(repositories)))
        },
        onRerun: {
          store.send(
            .rerunDetachedSession(
              id: session.id,
              repositories: Array(repositories)
            )
          )
        },
        onResume: (session.agent != nil && session.agentNativeSessionID != nil)
          ? {
            store.send(
              .resumeDetachedSession(
                id: session.id,
                repositories: Array(repositories)
              )
            )
          }
          : nil,
        onResumePicker: (session.agent != nil && session.agentNativeSessionID == nil)
          ? {
            store.send(
              .resumeDetachedSessionWithPicker(
                id: session.id,
                repositories: Array(repositories)
              )
            )
          }
          : nil,
        onRemove: { store.send(.removeSession(id: session.id)) },
        onRename: { beginRename(session) },
        onSwitcherMove: { direction in openSwitcher(direction: direction) },
        onAutoObserverToggle: { store.send(.toggleAutoObserver(id: session.id)) },
        onAutoObserverPromptChanged: { prompt in
          store.send(.setAutoObserverPrompt(id: session.id, prompt: prompt))
        }
      )
      .overlay {
        if isSessionSwitcherPresented {
          SessionSwitcherOverlay(
            sessions: switcherSessions,
            repositories: repositories,
            classify: { classify($0) },
            highlightedSessionID: $highlightedSessionID,
            onCommit: { commitSwitcher() },
            onCancel: { isSessionSwitcherPresented = false }
          )
        }
      }
      .overlay(alignment: .bottom) {
        if let pending = pendingExit {
          PendingExitBanner(
            destination: destinationLabel(pending.destination),
            startedAt: pending.startedAt,
            duration: pendingExitDelay,
            onCancel: { cancelPendingExit() },
          )
          .padding(.bottom, 24)
          .transition(.move(edge: .bottom).combined(with: .opacity))
        }
      }
      .animation(.easeOut(duration: 0.18), value: pendingExit)
    } else {
      boardContents
    }
  }

  private func beginRename(_ session: AgentSession) {
    renameDraft = session.displayName
    renamingSessionID = session.id
  }

  private func armAutoZoomBack(for focusedID: AgentSession.ID?) {
    guard let focusedID,
      let session = store.sessions.first(where: { $0.id == focusedID })
    else {
      autoZoomBackArmedSessionID = nil
      return
    }
    let isBusy = terminalManager.isAgentBusy(
      worktreeID: session.worktreeID,
      tabID: TerminalTabID(rawValue: session.id)
    )
    autoZoomBackArmedSessionID = isBusy ? nil : focusedID
  }

  // MARK: - Pending auto-exit

  private func schedulePendingExit(for focusedID: AgentSession.ID) {
    cancelPendingExit() // collapse any older countdown
    let destination = nextPendingDestination(excluding: focusedID)
    pendingExit = PendingExit(destination: destination, startedAt: Date())
    pendingExitTask = Task {
      try? await Task.sleep(for: pendingExitDelay)
      guard !Task.isCancelled else { return }
      await MainActor.run { commitPendingExit() }
    }
  }

  private func cancelPendingExit() {
    pendingExitTask?.cancel()
    pendingExitTask = nil
    pendingExit = nil
  }

  private func commitPendingExit() {
    guard let pending = pendingExit else { return }
    pendingExit = nil
    pendingExitTask = nil
    store.send(.focusSession(id: pending.destination))
  }

  private func installPendingExitEscapeMonitor() {
    guard pendingExitEscapeMonitor == nil else { return }
    pendingExitEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      guard pendingExit != nil else { return event }
      let plainModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      guard event.keyCode == 53, plainModifiers.isEmpty else {
        return event
      }
      cancelPendingExit()
      return nil
    }
  }

  private func removePendingExitEscapeMonitor() {
    guard let pendingExitEscapeMonitor else { return }
    NSEvent.removeMonitor(pendingExitEscapeMonitor)
    self.pendingExitEscapeMonitor = nil
  }

  /// Prefer `awaitingInput` (agent blocked on a permission prompt) over
  /// `waitingOnMe` (just idle). `nil` → fall back to the board.
  private func nextPendingDestination(
    excluding focusedID: AgentSession.ID
  ) -> AgentSession.ID? {
    let visible = store.visibleSessions.filter { $0.id != focusedID }
    if let s = visible.first(where: { classify($0) == .awaitingInput }) { return s.id }
    if let s = visible.first(where: { classify($0) == .waitingOnMe }) { return s.id }
    return nil
  }

  private func destinationLabel(_ id: AgentSession.ID?) -> String {
    guard let id, let session = store.sessions.first(where: { $0.id == id }) else {
      return "Returning to board"
    }
    return "Going to \(session.displayName)"
  }

  // MARK: - Session switcher

  /// Flat, repo-filtered session list the switcher cycles through.
  /// Uses `BoardNavOrder` to stay in sync with the board's arrow-key
  /// cursor.
  private var switcherSessions: [AgentSession] {
    let visible = store.visibleSessions
    let orderedIDs = BoardNavOrder.order(visibleSessions: visible, classify: classify)
    return orderedIDs.compactMap { id in visible.first(where: { $0.id == id }) }
  }

  /// Opens the switcher and pre-moves the cursor by ±1 so the first
  /// `⌘⌥←/→/↑/↓` press already shows the user where they're heading.
  private func openSwitcher(direction: Int) {
    let sessions = switcherSessions
    guard !sessions.isEmpty else { return }
    let ids = sessions.map(\.id)
    let currentIndex = highlightedSessionID.flatMap { ids.firstIndex(of: $0) }
      ?? (store.focusedSessionID.flatMap { ids.firstIndex(of: $0) } ?? 0)
    let next = (currentIndex + direction + ids.count) % ids.count
    highlightedSessionID = ids[next]
    isSessionSwitcherPresented = true
  }

  private func commitSwitcher() {
    isSessionSwitcherPresented = false
    if let id = highlightedSessionID, id != store.focusedSessionID {
      store.send(.focusSession(id: id))
    }
  }

  private var boardContents: some View {
    BoardView(
      store: store,
      repositories: repositories,
      terminalManager: terminalManager,
      classify: { classify($0) },
      onAddRepository: onAddRepository,
      onRenameSession: { session in beginRename(session) },
      highlightedSessionID: $highlightedSessionID
    )
    // The window title is still "Supacool" (visible in the menu bar
    // and Window menu) but we hide it from the toolbar chrome — the
    // leading item is just the repo picker.
    .toolbar(removing: .title)
    .toolbar {
      ToolbarItem(placement: .navigation) {
        RepoPickerButton(
          repositories: repositories,
          filters: store.filters,
          onToggleRepository: { store.send(.toggleRepository(id: $0)) },
          onShowAll: { store.send(.showAllRepositories) },
          onAddRepository: onAddRepository,
          onConfigureRepositories: onConfigureRepositories,
          onPruneWorktrees: { repo in
            store.send(
              .pruneWorktreesRequested(repositoryID: repo.id, repositoryName: repo.name)
            )
          }
        )
      }
      // Push the + button to the far right so there's breathing room
      // between the title/repo block and the action.
      ToolbarSpacer(.flexible)
      ToolbarItem(placement: .primaryAction) {
        Button {
          store.send(.openNewTerminalSheet(repositories: Array(repositories)))
        } label: {
          Label("New Terminal", systemImage: "plus")
        }
        .help("New Terminal (⌘N)")
        .disabled(repositories.isEmpty)
      }
      #if DEBUG
        ToolbarItem(placement: .automatic) {
          Button {
            store.send(.createSession(Self.fakeSession()))
          } label: {
            Label("Debug: Add Fake Session", systemImage: "hammer")
          }
          .help("Insert a fake session for UI testing (DEBUG only)")
        }
      #endif
    }
  }

  /// Classifier reads live busy state from WorktreeTerminalManager and the
  /// persisted last-known-busy flag on the session.
  ///
  /// Tab doesn't exist anymore:
  /// - `lastKnownBusy=true`: the agent was working when the app went away
  ///   (crash / quit mid-turn). Card reads as .interrupted (yellow warning).
  /// - `lastKnownBusy=false`: the agent was idle. Card reads as .detached
  ///   (moon icon, gray). Safe and expected after a normal relaunch.
  ///
  /// Tab exists:
  /// - Busy → .inProgress.
  /// - Not busy, inside the 3s grace period after creation → .fresh so
  ///   cards don't immediately flip to Waiting while claude/codex is
  ///   starting up.
  /// - Not busy, past grace or has completed at least once → .waitingOnMe.
  /// Busy state of whichever session is currently focused, if any.
  /// `.onChange` on this drives the auto-zoom-back-on-prompt behavior.
  /// Reading `terminalManager.isAgentBusy(...)` within this computed
  /// property hooks into @Observable tracking so the value refreshes
  /// when the agent's busy flag flips.
  private var focusedSessionBusyState: Bool {
    guard let focusedID = store.focusedSessionID,
      let session = store.sessions.first(where: { $0.id == focusedID })
    else { return false }
    return terminalManager.isAgentBusy(
      worktreeID: session.worktreeID,
      tabID: TerminalTabID(rawValue: session.id)
    )
  }

  private func classify(_ session: AgentSession) -> BoardSessionStatus {
    let tabID = TerminalTabID(rawValue: session.id)
    return BoardSessionStatus.classify(
      session: session,
      tabExists: terminalManager.sessionTabExists(worktreeID: session.worktreeID, tabID: tabID),
      awaitingInput: terminalManager.isAwaitingInput(worktreeID: session.worktreeID, tabID: tabID),
      busy: terminalManager.isAgentBusy(worktreeID: session.worktreeID, tabID: tabID)
    )
  }

  /// One hidden watcher per session, regardless of which mode (board or
  /// full-screen) is currently rendered. Forwards busy/status edges to
  /// the reducer so auto-observer triggers fire even while the cards
  /// are torn down inside a focused session.
  @ViewBuilder
  private var sessionStateWatchers: some View {
    ForEach(store.sessions) { session in
      SessionStateWatcher(
        session: session,
        terminalManager: terminalManager,
        classify: { classify($0) },
        onBusyStateChange: { newBusy in
          store.send(.updateSessionBusyState(id: session.id, busy: newBusy))
        },
        onBusyToIdleTransition: {
          store.send(.markSessionCompletedOnce(id: session.id))
          store.send(.autoObserverTriggered(id: session.id))
        },
        onAwaitingInputEntered: {
          store.send(.autoObserverTriggered(id: session.id))
        }
      )
    }
  }

  #if DEBUG
    private static func fakeSession() -> AgentSession {
      let prompts = [
        "Refactor auth module to async/await",
        "Write unit tests for payment service",
        "Document the new webhook endpoints",
        "Fix flaky integration tests",
        "Investigate slow database query",
      ]
      return AgentSession(
        repositoryID: "/tmp/fake-repo",
        worktreeID: "/tmp/fake-repo",
        agent: Bool.random() ? .claude : .codex,
        initialPrompt: prompts.randomElement() ?? "Debug session",
        hasCompletedAtLeastOnce: Bool.random()
      )
    }
  #endif
}

// MARK: - Prune alert

/// Lifts the prune-summary alert out of `BoardRootView.body` into its own
/// ViewModifier. The root view's modifier chain was long enough to push
/// the Swift type-checker past its "reasonable time" budget; extracting
/// this branch keeps body compilable without changing behaviour.
private struct PruneAlertModifier: ViewModifier {
  @Bindable var store: StoreOf<BoardFeature>

  func body(content: Content) -> some View {
    content.alert(
      title,
      isPresented: Binding(
        get: { store.pruneAlert != nil },
        set: { if !$0 { store.send(.dismissPruneAlert) } }
      ),
      presenting: store.pruneAlert,
      actions: buttons,
      message: { alert in Text(message(for: alert)) }
    )
  }

  private var title: String {
    guard let name = store.pruneAlert?.repositoryName else { return "Prune worktrees" }
    return "Prune \(name)"
  }

  @ViewBuilder
  private func buttons(for alert: BoardFeature.PruneAlertState) -> some View {
    switch alert.outcome {
    case .success(_, let orphanSessionIDs) where !orphanSessionIDs.isEmpty:
      Button("Remove orphans", role: .destructive) {
        store.send(.confirmPruneOrphans(sessionIDs: orphanSessionIDs))
      }
      Button("Keep", role: .cancel) { store.send(.dismissPruneAlert) }
    case .success, .failure:
      Button("OK", role: .cancel) { store.send(.dismissPruneAlert) }
    }
  }

  private func message(for alert: BoardFeature.PruneAlertState) -> String {
    switch alert.outcome {
    case .success(let prunedCount, let orphanSessionIDs):
      return successMessage(prunedCount: prunedCount, orphanCount: orphanSessionIDs.count)
    case .failure(let message):
      return message
    }
  }

  private func successMessage(prunedCount: Int, orphanCount: Int) -> String {
    switch (prunedCount, orphanCount) {
    case (0, 0):
      return "Nothing to prune."
    case (let n, 0):
      return "Pruned \(n) stale worktree \(n == 1 ? "ref" : "refs")."
    case (0, let m):
      return
        "No stale refs, but found \(m) orphan session \(m == 1 ? "card" : "cards") "
        + "(worktree is gone from disk). Remove them?"
    case (let n, let m):
      return
        "Pruned \(n) stale worktree \(n == 1 ? "ref" : "refs"). "
        + "Found \(m) orphan session \(m == 1 ? "card" : "cards") "
        + "(worktree is gone from disk). Remove them?"
    }
  }
}
