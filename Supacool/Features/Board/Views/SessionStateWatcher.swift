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
  /// Per-terminal busy persistence: (terminalID, newBusy). Fired for each
  /// tracked terminal whose live busy state changed, so every agent keeps
  /// its own `lastKnownBusy` for the relaunch detached/interrupted split.
  let onBusyStateChange: (UUID, Bool) -> Void
  let onBusyToIdleTransition: () -> Void
  let onAwaitingInputEntered: () -> Void
  let onPriorityTermination: (BoardSessionStatus) -> Void
  let onStatusObserved: (BoardSessionStatus) -> Void
  let onTabPresenceObserved: (Bool) -> Void

  /// Session-level busy (any agent tab busy) — drives the busy→idle
  /// completion edge, not persistence.
  private var isBusyNow: Bool {
    terminalManager.isSessionBusy(for: session)
  }

  /// Live busy per busy-tracked terminal. Tab terminals read the tab's
  /// fused busy; adopted pane terminals read their own surface's latch.
  private var busyByTerminal: [UUID: Bool] {
    var result: [UUID: Bool] = [:]
    for terminal in session.busyTrackedTerminals {
      if terminal.hostTabID != nil {
        result[terminal.id] = terminalManager.isAgentSurfaceBusy(
          worktreeID: session.worktreeID,
          surfaceID: terminal.id
        )
      } else {
        result[terminal.id] = terminalManager.isAgentBusy(
          worktreeID: session.worktreeID,
          tabID: TerminalTabID(rawValue: terminal.id)
        )
      }
    }
    return result
  }

  private var status: BoardSessionStatus { classify(session) }

  private var tabExistsNow: Bool {
    terminalManager.sessionTabExists(
      worktreeID: session.worktreeID,
      tabID: TerminalTabID(rawValue: session.id)
    )
  }

  var body: some View {
    Color.clear
      .frame(width: 0, height: 0)
      .accessibilityHidden(true)
      .onChange(of: isBusyNow) { oldValue, newValue in
        if oldValue && !newValue {
          onBusyToIdleTransition()
        }
      }
      .onChange(of: busyByTerminal) { oldValue, newValue in
        // Persist per-terminal busy so relaunches can tell .detached
        // (was idle) from .interrupted (was working) for EACH agent.
        for (terminalID, busy) in newValue where oldValue[terminalID] != busy {
          onBusyStateChange(terminalID, busy)
        }
      }
      .onChange(of: status) { oldValue, newValue in
        onStatusObserved(newValue)
        // Fire auto-observer when the session enters awaiting-input.
        if oldValue != .awaitingInput && newValue == .awaitingInput {
          onAwaitingInputEntered()
        }
        if session.isPriority, Self.didTerminate(from: oldValue, to: newValue) {
          onPriorityTermination(newValue)
        }
      }
      .onChange(of: tabExistsNow) { _, newValue in
        onTabPresenceObserved(newValue)
      }
      .onAppear {
        onTabPresenceObserved(tabExistsNow)
        onStatusObserved(status)
        // Reconcile: if a stored busy flag doesn't match reality at
        // mount time (e.g. freshly loaded), sync it once — per terminal.
        let live = busyByTerminal
        for terminal in session.busyTrackedTerminals {
          if let liveBusy = live[terminal.id], terminal.lastKnownBusy != liveBusy {
            onBusyStateChange(terminal.id, liveBusy)
          }
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
    case .inProgress, .waitingForChecks, .waitingOnMe, .awaitingInput, .fresh:
      return true
    case .detached, .interrupted, .parked, .disconnected:
      return false
    }
  }
}
