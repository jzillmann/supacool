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

  var body: some View {
    let state = manager.state(for: worktree) { false }
    Group {
      if state.containsTabTree(tabID) {
        TerminalSplitTreeAXContainer(tree: state.splitTree(for: tabID)) { operation in
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
      }
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
