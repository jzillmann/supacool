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
    .toolbar {
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

  /// Phase 4d classifier: reads live busy state from WorktreeTerminalManager.
  /// Detached sessions (tab no longer exists) sink to the Waiting section
  /// with a moon icon — common after app relaunch since PTYs don't survive.
  /// Fresh sessions (<3s old) stay in the In Progress section even if the
  /// agent hasn't signalled busy yet, so they don't immediately pop to
  /// "Waiting" while claude/codex is still starting up.
  private func classify(_ session: AgentSession) -> SessionCardView.Status {
    let tabID = TerminalTabID(rawValue: session.id)
    if !terminalManager.sessionTabExists(worktreeID: session.worktreeID, tabID: tabID) {
      return session.hasCompletedAtLeastOnce ? .detached : .fresh
    }
    if terminalManager.isAgentBusy(worktreeID: session.worktreeID, tabID: tabID) {
      return .inProgress
    }
    // Not busy and tab exists: either the agent finished a turn (→ waiting)
    // or it's still warming up (→ fresh grace period).
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
