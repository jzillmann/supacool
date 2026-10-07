import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import Supacool

/// ⌘1–⌘9 and ⌘⇧[ / ⌘⇧] used to compute their target in the full-screen
/// view, from values SwiftUI never refreshed on the hidden shortcut buttons:
/// ⌘⇧] moved once and then never again, ⌘1–⌘9 worked only sometimes. The
/// reducer resolves the focused session and its active tab on every press.
@MainActor
struct BoardTabCycleTests {
  @Test(.dependencies) func cyclingWalksFromTheLiveActiveTabAndWraps() async {
    let (session, shellID) = twoTabSession()
    let store = focusedStore(sessions: [session], focused: session.id)

    await store.send(.cycleFocusedSessionTab(step: 1)) {
      $0.activeTerminalBySession[session.id] = shellID
    }
    await store.send(.cycleFocusedSessionTab(step: -1)) {
      $0.activeTerminalBySession[session.id] = session.primaryTerminalID
    }
    await store.send(.cycleFocusedSessionTab(step: -1)) {
      $0.activeTerminalBySession[session.id] = shellID
    }
    await store.send(.cycleFocusedSessionTab(step: 1)) {
      $0.activeTerminalBySession[session.id] = session.primaryTerminalID
    }
  }

  @Test(.dependencies) func digitsPickTabsOfTheFocusedSessionOnly() async {
    let (other, _) = twoTabSession()
    let (focused, shellID) = twoTabSession()
    let store = focusedStore(sessions: [other, focused], focused: focused.id)

    await store.send(.selectFocusedSessionTab(digit: 2)) {
      $0.activeTerminalBySession[focused.id] = shellID
    }
    await store.send(.selectFocusedSessionTab(digit: 1)) {
      $0.activeTerminalBySession[focused.id] = focused.primaryTerminalID
    }
    // ⌘9 is the last tab; a digit past the strip does nothing.
    await store.send(.selectFocusedSessionTab(digit: 9)) {
      $0.activeTerminalBySession[focused.id] = shellID
    }
    await store.send(.selectFocusedSessionTab(digit: 3))
  }

  @Test(.dependencies) func tabKeysDoNothingOnTheBoardOrInASingleTabSession() async {
    let single = AgentSession(
      repositoryID: "/tmp/repo",
      worktreeID: "/tmp/repo",
      agent: .claude,
      initialPrompt: "Fix the ticket"
    )
    let onBoard = focusedStore(sessions: [single], focused: nil)
    await onBoard.send(.cycleFocusedSessionTab(step: 1))
    await onBoard.send(.selectFocusedSessionTab(digit: 1))

    let inSession = focusedStore(sessions: [single], focused: single.id)
    await inSession.send(.cycleFocusedSessionTab(step: 1))
  }

  private func twoTabSession() -> (AgentSession, shellID: UUID) {
    let shellID = UUID()
    var session = AgentSession(
      repositoryID: "/tmp/repo",
      worktreeID: "/tmp/repo",
      agent: .claude,
      initialPrompt: "Fix the ticket"
    )
    // A pane lives inside its host tab's split tree, not in the strip.
    session.terminals.append(SessionTerminal(role: .shell, hostTabID: session.primaryTerminalID))
    session.terminals.append(SessionTerminal(id: shellID, role: .shell))
    return (session, shellID)
  }

  private func focusedStore(
    sessions: [AgentSession],
    focused: AgentSession.ID?
  ) -> TestStoreOf<BoardFeature> {
    var state = BoardFeature.State()
    state.$sessions.withLock { $0 = sessions }
    state.focusedSessionID = focused
    return TestStore(initialState: state) { BoardFeature() }
  }
}
