import Dependencies
import DependenciesTestSupport
import Foundation
import Testing

@testable import Supacool

/// Exercises `WorktreeTerminalState.claimSessionView` / `releaseSessionView`,
/// the guard that keeps a dying `SingleSessionTerminalView` instance from
/// pausing renderers its replacement just resumed. SwiftUI fires the incoming
/// view's `onAppear` before the outgoing view's `onDisappear` when swapping
/// board↔session content, so an unguarded pause from the old instance would
/// freeze the visible terminal (keys reach the PTY, nothing repaints).
@MainActor
struct SessionViewClaimTests {
  @Test(.dependencies) func claimSetsCurrentToken() {
    let state = makeState()
    let token = state.claimSessionView()
    #expect(state.sessionViewToken == token)
  }

  @Test(.dependencies) func releaseWithCurrentTokenClearsClaim() {
    let state = makeState()
    let token = state.claimSessionView()
    state.releaseSessionView(token)
    #expect(state.sessionViewToken == nil)
  }

  /// The core race: view A claims, view B claims (user re-entered the
  /// session), then A's late onDisappear releases with its stale token.
  /// B's claim must survive so B's resumed renderers stay running.
  @Test(.dependencies) func staleReleaseDoesNotClearNewerClaim() {
    let state = makeState()
    let tokenA = state.claimSessionView()
    let tokenB = state.claimSessionView()
    state.releaseSessionView(tokenA)
    #expect(state.sessionViewToken == tokenB)
  }

  @Test(.dependencies) func releaseAfterClearIsIgnored() {
    let state = makeState()
    let token = state.claimSessionView()
    state.releaseSessionView(token)
    // Double-release (e.g. onDisappear firing twice) must be harmless.
    state.releaseSessionView(token)
    #expect(state.sessionViewToken == nil)
  }

  private func makeState() -> WorktreeTerminalState {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = Worktree(
      id: "/tmp/repo/wt-claim",
      name: "wt-claim",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-claim"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo"),
    )
    return manager.state(for: worktree) { false }
  }
}
