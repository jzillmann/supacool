import Foundation

/// At-a-glance session counts for the board header, bucketed exactly the
/// way `BoardView` lays the sections out so the numbers always add up to
/// what's on screen. Pure aggregation — computed from the (already
/// repo-filtered) visible sessions and the same `classify` closure the
/// board uses.
nonisolated struct BoardVitals: Equatable {
  /// Needs me — the "Waiting on Me" bucket (waitingOnMe, awaitingInput,
  /// detached, interrupted, disconnected).
  var waiting: Int
  /// Agent is busy — the "In Progress" bucket (inProgress, fresh).
  var working: Int
  /// Blocked on external CI/review — the "Waiting on External" bucket.
  var external: Int
  /// Parked but still holding a live terminal — the "Standby" bucket.
  var standby: Int
  /// Parked and cold — the "Parked" bucket.
  var parked: Int

  /// Every visible session, dormant included.
  var total: Int { waiting + working + external + standby + parked }

  /// Non-dormant sessions — the ones actually in rotation.
  var live: Int { waiting + working + external }

  static let empty = BoardVitals(waiting: 0, working: 0, external: 0, standby: 0, parked: 0)

  static func tally(
    sessions: [AgentSession],
    classify: (AgentSession) -> BoardSessionStatus
  ) -> BoardVitals {
    var vitals = BoardVitals.empty
    for session in sessions {
      let status = classify(session)
      // Bucketing mirrors `BoardNavOrder` (and thus `BoardView`'s
      // sections). Inlined here rather than delegated because those
      // helpers are `@MainActor`-isolated and this stays a pure,
      // off-main value type; the switch is exhaustive so any new status
      // forces a compile-time decision here too.
      switch status {
      case .parked:
        if session.parkedActive {
          vitals.standby += 1
        } else {
          vitals.parked += 1
        }
      case .waitingForChecks:
        vitals.external += 1
      case .waitingOnMe, .awaitingInput, .detached, .interrupted, .disconnected:
        vitals.waiting += 1
      case .inProgress, .fresh:
        vitals.working += 1
      }
    }
    return vitals
  }
}
