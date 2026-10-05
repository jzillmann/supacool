import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import Supacool

@MainActor
struct BoardTabCycleTests {
  /// ⌘⇧[ / ⌘⇧] used to compute their target in the view, from a value
  /// SwiftUI never refreshed: the key moved once, then never again. The
  /// reducer has to walk from the *current* active tab on every press.
  @Test(.dependencies) func cyclingWalksFromTheLiveActiveTabAndWraps() async {
    let shellID = UUID()
    let paneID = UUID()
    var session = AgentSession(
      repositoryID: "/tmp/repo",
      worktreeID: "/tmp/repo",
      agent: .claude,
      initialPrompt: "Fix the ticket"
    )
    // A pane lives inside its host tab's split tree, not in the strip.
    session.terminals.append(SessionTerminal(id: paneID, role: .shell, hostTabID: session.primaryTerminalID))
    session.terminals.append(SessionTerminal(id: shellID, role: .shell))
    let state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }
    let store = TestStore(initialState: state) { BoardFeature() }

    await store.send(.cycleActiveTerminal(sessionID: session.id, step: 1)) {
      $0.activeTerminalBySession[session.id] = shellID
    }
    await store.send(.cycleActiveTerminal(sessionID: session.id, step: -1)) {
      $0.activeTerminalBySession[session.id] = session.primaryTerminalID
    }
    await store.send(.cycleActiveTerminal(sessionID: session.id, step: -1)) {
      $0.activeTerminalBySession[session.id] = shellID
    }
    await store.send(.cycleActiveTerminal(sessionID: session.id, step: 1)) {
      $0.activeTerminalBySession[session.id] = session.primaryTerminalID
    }
  }

  @Test(.dependencies) func cyclingASingleTabSessionDoesNothing() async {
    let session = AgentSession(
      repositoryID: "/tmp/repo",
      worktreeID: "/tmp/repo",
      agent: .claude,
      initialPrompt: "Fix the ticket"
    )
    let state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }
    let store = TestStore(initialState: state) { BoardFeature() }

    await store.send(.cycleActiveTerminal(sessionID: session.id, step: 1))
  }
}
