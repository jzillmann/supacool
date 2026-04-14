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
  /// the full-screen terminal. Opened by `⌘←/→/↑/↓`, committed on ⌘
  /// release (see `SessionSwitcherOverlay`).
  @State private var isSessionSwitcherPresented: Bool = false

  /// Auto-zoom back to the board the moment a submitted prompt kicks the
  /// agent from idle → busy, so the user can see the whole fleet at a
  /// glance while the agent works. Gated on
  /// `session.hasCompletedAtLeastOnce` so a session's *initial* launch
  /// doesn't bounce out.
  @AppStorage("supacool.autoZoomBackOnPrompt") private var autoZoomBackOnPrompt: Bool = true

  var body: some View {
    Group {
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
          onSwitcherMove: { direction in openSwitcher(direction: direction) }
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
      } else {
        boardContents
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.background)
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
    .onChange(of: store.focusedSessionID) { _, newValue in
      if let newValue { highlightedSessionID = newValue }
    }
    // Auto-zoom back to the board when the focused session's agent
    // transitions idle → busy — that's the signal the user just
    // submitted a prompt. Gated on hasCompletedAtLeastOnce so we don't
    // bounce out of a session's initial auto-launch.
    .onChange(of: focusedSessionBusyState) { oldValue, newValue in
      guard autoZoomBackOnPrompt else { return }
      guard oldValue == false, newValue == true else { return }
      guard let focusedID = store.focusedSessionID,
        let session = store.sessions.first(where: { $0.id == focusedID }),
        session.hasCompletedAtLeastOnce
      else { return }
      store.send(.focusSession(id: nil))
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
  }

  private func beginRename(_ session: AgentSession) {
    renameDraft = session.displayName
    renamingSessionID = session.id
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
  /// `⌘←/→/↑/↓` press already shows the user where they're heading.
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
          onConfigureRepositories: onConfigureRepositories
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

  private func classify(_ session: AgentSession) -> SessionCardView.Status {
    // User-parked wins over everything else: we've deliberately freed the
    // PTY, so tab-existence checks below would flag it as .detached.
    if session.parked {
      return .parked
    }
    let tabID = TerminalTabID(rawValue: session.id)
    if !terminalManager.sessionTabExists(worktreeID: session.worktreeID, tabID: tabID) {
      return session.lastKnownBusy ? .interrupted : .detached
    }
    // Awaiting-input wins over busy: the agent may technically still hold
    // the busy flag while it's blocked on a permission prompt, but from
    // the user's perspective the card needs attention, not patience.
    if terminalManager.isAwaitingInput(worktreeID: session.worktreeID, tabID: tabID) {
      return .awaitingInput
    }
    if terminalManager.isAgentBusy(worktreeID: session.worktreeID, tabID: tabID) {
      return .inProgress
    }
    let graceSeconds: TimeInterval = 3
    if !session.hasCompletedAtLeastOnce,
      Date().timeIntervalSince(session.createdAt) < graceSeconds
    {
      return .fresh
    }
    return .waitingOnMe
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
