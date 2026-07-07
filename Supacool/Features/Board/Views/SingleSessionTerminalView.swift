import AppKit
import SwiftUI

/// Renders a single ghostty tab's split tree — no tab bar, no sibling tabs.
///
/// Supacool's board is the equivalent of a tab bar: each card is one
/// session. When the user taps into a session's full-screen view, they
/// should see only that session's terminal content, not the whole
/// worktree's tab strip (which would expose other sessions that happen
/// to share the same backing worktree).
///
/// Sets the backing `WorktreeTerminalState.selectedTabId` to the passed
/// tab on appear so keyboard shortcuts + focus routing still work
/// through supacode's existing machinery.
struct SingleSessionTerminalView: View {
  let worktree: Worktree
  let tabID: TerminalTabID
  let manager: WorktreeTerminalManager

  @State private var windowActivity = WindowActivityState.inactive
  /// Claim on the shared `WorktreeTerminalState` proving this instance is
  /// the one currently presenting its surfaces. `onDisappear` may only
  /// pause renderers while the claim is still ours — see
  /// `WorktreeTerminalState.claimSessionView`.
  @State private var sessionViewToken: UUID?

  var body: some View {
    let state = manager.state(for: worktree) { false }
    let unfocusedSplitOverlay = manager.unfocusedSplitOverlay()
    Group {
      if state.containsTabTree(tabID) {
        TerminalSplitTreeAXContainer(
          tree: state.splitTree(for: tabID),
          activeSurfaceID: state.activeSurfaceID(for: tabID),
          unfocusedSplitOverlay: unfocusedSplitOverlay
        ) { operation in
          state.performSplitOperation(operation, in: tabID)
        }
      } else {
        EmptyTerminalPaneView(message: "Terminal no longer running")
      }
    }
    .background(
      WindowFocusObserverView { activity in
        windowActivity = activity
        state.syncFocus(windowIsKey: activity.isKeyWindow, windowIsVisible: activity.isVisible)
      }
    )
    .onAppear {
      sessionViewToken = state.claimSessionView()
      // Align the worktree state's selected tab to the session's tab so
      // any bar-less commands (close-surface, split, binding actions)
      // target the right one.
      if state.tabManager.selectedTabId != tabID {
        state.selectTab(tabID)
      }
      state.focusSelectedTab()
      let activity = resolvedWindowActivity
      state.syncFocus(windowIsKey: activity.isKeyWindow, windowIsVisible: activity.isVisible)
      // BoardView claims first-responder via `.focusable()` while it's
      // on screen. When the user enters a session, the synchronous
      // focusSelectedTab above schedules a moveFocus Task — but
      // SwiftUI is still tearing down the BoardView's responder in
      // parallel, and its hidden focus area can keep stealing
      // first-responder back. The visible symptom: typing does
      // nothing until the user switches tabs and back, at which
      // point the buffered keystrokes appear because Ghostty already
      // thought it was focused (focusDidChange(true) ran from
      // applySurfaceActivity), but AppKit was routing keys
      // elsewhere. Re-assert on the next runloop tick to win the
      // race after the BoardView's responder has resigned.
      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(50))
        state.focusSelectedTab()
        // Re-evaluate window activity once the board→session transition
        // has settled. The synchronous syncFocus above reads
        // NSApp.keyWindow, which can be briefly nil mid-transition and
        // resolve to `.inactive` — pausing the surface's Ghostty renderer
        // via setOcclusion(false). Because the window's real key/occlusion
        // state never changes during in-app navigation, WindowFocusObserver
        // never re-fires, so nothing un-pauses the renderer: keystrokes
        // reach the PTY but the screen never repaints until the user
        // leaves and returns (a manual second evaluation). Re-syncing here
        // is that second evaluation, automatically.
        let settled = resolvedWindowActivity
        state.syncFocus(windowIsKey: settled.isKeyWindow, windowIsVisible: settled.isVisible)
      }
    }
    .onDisappear {
      // Tell the worktree state its surfaces are no longer on-screen so
      // Ghostty's per-surface Metal renderers pause. Without this, every
      // session the user has ever opened in a run keeps its renderer
      // thread painting full-bore in the background — a 30s sample of a
      // hot app showed 8 surfaces cumulatively burning ~200% of one
      // core in the renderer pool. syncFocus → applySurfaceActivity
      // recomputes per-surface visibility and calls setOcclusion(false)
      // on each leaf, which is the upstream lever for renderer pausing.
      //
      // Released through the claim token because this onDisappear can
      // fire AFTER a replacement instance's onAppear (SwiftUI tears the
      // outgoing subtree down late, e.g. behind a transition). An
      // unconditional pause here would then undo the resume the new
      // instance just performed on the same shared state, leaving a
      // frozen terminal: keys reach the PTY but nothing repaints until
      // the user leaves and re-enters. The state ignores the release
      // when the token is stale.
      guard let sessionViewToken else { return }
      state.releaseSessionView(sessionViewToken)
    }
  }

  private var resolvedWindowActivity: WindowActivityState {
    if let keyWindow = NSApp.keyWindow {
      return WindowActivityState(
        isKeyWindow: keyWindow.isKeyWindow,
        isVisible: keyWindow.occlusionState.contains(.visible)
      )
    }
    return windowActivity
  }
}
