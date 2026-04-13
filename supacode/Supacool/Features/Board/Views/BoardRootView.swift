import ComposableArchitecture
import SwiftUI

/// Top-level Matrix Board container. Swaps between the board grid and a
/// full-screen terminal view based on `focusedSessionID`.
///
/// Wired into `ContentView` behind a debug toggle in Phase 4b; becomes the
/// primary root in Phase 4f when the sidebar is retired.
struct BoardRootView: View {
  @Bindable var store: StoreOf<BoardFeature>
  let repositories: IdentifiedArrayOf<Repository>
  let terminalManager: WorktreeTerminalManager

  var body: some View {
    Group {
      if let focusedID = store.focusedSessionID,
        let session = store.sessions.first(where: { $0.id == focusedID })
      {
        // Phase 4e replaces this placeholder with the real terminal view.
        fullScreenPlaceholder(for: session)
      } else {
        boardContents
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.background)
  }

  private var boardContents: some View {
    BoardView(
      store: store,
      repositories: repositories,
      classify: { classify($0) }
    )
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          store.send(.openNewTerminalSheet(repositories: Array(repositories)))
        } label: {
          Label("New Terminal", systemImage: "plus")
        }
        .help("New Terminal (⌘N)")
        .keyboardShortcut("n", modifiers: .command)
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
    .sheet(
      store: store.scope(state: \.$newTerminalSheet, action: \.newTerminalSheet)
    ) { sheetStore in
      NewTerminalSheet(store: sheetStore)
    }
  }

  private func fullScreenPlaceholder(for session: AgentSession) -> some View {
    VStack(spacing: 16) {
      HStack {
        Button {
          store.send(.focusSession(id: nil))
        } label: {
          Label("Back to Board", systemImage: "chevron.left")
        }
        .keyboardShortcut(.escape, modifiers: [])
        .help("Return to board (Esc)")
        Spacer()
      }
      .padding()
      VStack(spacing: 10) {
        Image(systemName: "terminal.fill")
          .font(.system(size: 48))
          .foregroundStyle(.secondary)
        Text(session.displayName)
          .font(.title2)
        Text("Full-screen terminal will render here in Phase 4e.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  /// Phase 4b classifier: simple heuristic based on `hasCompletedAtLeastOnce`
  /// so the two sections populate correctly in DEBUG. Phase 4d replaces this
  /// with a live busy-state observer from WorktreeTerminalManager, and
  /// Phase 4g adds the `.detached` case.
  private func classify(_ session: AgentSession) -> SessionCardView.Status {
    session.hasCompletedAtLeastOnce ? .waitingOnMe : .fresh
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
