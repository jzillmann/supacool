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
          onRemove: { store.send(.removeSession(id: session.id)) }
        )
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
    // Sheet lives at the root so it's reachable whether you're looking at
    // the board or at a full-screen terminal.
    .sheet(
      store: store.scope(state: \.$newTerminalSheet, action: \.newTerminalSheet)
    ) { sheetStore in
      NewTerminalSheet(store: sheetStore)
    }
  }

  private var boardContents: some View {
    BoardView(
      store: store,
      repositories: repositories,
      terminalManager: terminalManager,
      classify: { classify($0) },
      onAddRepository: onAddRepository
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
  private func classify(_ session: AgentSession) -> SessionCardView.Status {
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
