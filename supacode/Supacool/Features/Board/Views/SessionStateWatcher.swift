import SwiftUI

/// Hidden per-session observer that watches busy/status transitions and
/// forwards them to the BoardFeature reducer. Lives at the BoardRootView
/// level (not on the cards) so it keeps firing while the user is inside
/// a full-screen terminal — without this, auto-observer wouldn't trigger
/// for the focused session because its card is torn down during the
/// board → terminal transition.
struct SessionStateWatcher: View {
  let session: AgentSession
  let terminalManager: WorktreeTerminalManager
  let classify: (AgentSession) -> BoardSessionStatus
  let onBusyStateChange: (Bool) -> Void
  let onBusyToIdleTransition: () -> Void
  let onAwaitingInputEntered: () -> Void
  let onPriorityTermination: (BoardSessionStatus) -> Void

  private var isBusyNow: Bool {
    terminalManager.isAgentBusy(
      worktreeID: session.worktreeID,
      tabID: TerminalTabID(rawValue: session.id)
    )
  }

  private var status: BoardSessionStatus { classify(session) }

  var body: some View {
    Color.clear
      .frame(width: 0, height: 0)
      .accessibilityHidden(true)
      .onChange(of: isBusyNow) { oldValue, newValue in
        // Persist the new busy state so relaunches can tell .detached
        // (was idle) from .interrupted (was working).
        onBusyStateChange(newValue)
        if oldValue && !newValue {
          onBusyToIdleTransition()
        }
      }
      .onChange(of: status) { oldValue, newValue in
        // Fire auto-observer when the session enters awaiting-input.
        if oldValue != .awaitingInput && newValue == .awaitingInput {
          onAwaitingInputEntered()
        }
        if session.isPriority, Self.didTerminate(from: oldValue, to: newValue) {
          onPriorityTermination(newValue)
        }
      }
      .onAppear {
        // Reconcile: if our stored busy flag doesn't match reality at
        // mount time (e.g. freshly loaded), sync it once.
        if session.lastKnownBusy != isBusyNow {
          onBusyStateChange(isBusyNow)
        }
      }
  }

  private static func didTerminate(
    from oldValue: BoardSessionStatus,
    to newValue: BoardSessionStatus
  ) -> Bool {
    guard oldValue != newValue else { return false }
    guard newValue == .detached || newValue == .interrupted else { return false }
    switch oldValue {
    case .inProgress, .waitingOnMe, .awaitingInput, .fresh:
      return true
    case .detached, .interrupted, .parked, .disconnected:
      return false
    }
  }
}
