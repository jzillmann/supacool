import Foundation

/// What the agent in a terminal tab is doing *right now* — the single
/// live-activity value the board classifies against.
///
/// Before this existed, `BoardSessionStatus.classify` fused three
/// independent booleans (`busy`, `awaitingInput`, `deferredWork`), each
/// backed by its own latch and TTL inside `WorktreeTerminalManager`. Nothing
/// owned the question "is this agent working?", so the latches could
/// disagree and the card fell through to Waiting whenever *all* of them
/// happened to be false — which is exactly what happens during a long,
/// hook-silent stretch of model thinking (trace D5AF6FE4). Collapsing them
/// into one value gives that question a single answer and one place to fix.
///
/// `WorktreeTerminalManager.agentActivity(worktreeID:tabID:)` is the only
/// producer. Ordering there is significant and mirrors the old boolean
/// precedence: a pending prompt outranks busy, which outranks a deferred
/// lease.
///
/// Not persisted — it is recomputed from live terminal state on every
/// render. The *persisted* card state is `BoardSessionStatus`.
nonisolated enum AgentActivity: String, Equatable, Sendable {
  /// The agent owns the turn: a busy hook is latched, its own UI is showing
  /// the interrupt hint, or we optimistically assume work after a submit.
  case working

  /// The agent has yielded and is blocked on the user — permission prompt,
  /// clarifying question, plan approval.
  case wantsInput

  /// The agent ended its turn *on purpose* while something external runs
  /// (CI, a poller, a timed re-check) and will pick the work back up. Held
  /// on a lease; reads as "Working" on the board, not as idle.
  case deferredWork

  /// Nobody is working and nothing is pending — the next move is the user's.
  case idle

  /// Merge the activities of a session's agent terminals under "working
  /// wins": the session reads In Progress while ANY agent is mid-turn, and
  /// only lands in Wants Input / Waiting on Me once no agent is working.
  /// Identity for a single element, so single-agent sessions are unchanged.
  static func mergedWorkingWins(_ activities: some Sequence<AgentActivity>) -> AgentActivity {
    var merged = AgentActivity.idle
    for activity in activities {
      switch activity {
      case .working:
        return .working
      case .deferredWork:
        merged = .deferredWork
      case .wantsInput:
        if merged != .deferredWork { merged = .wantsInput }
      case .idle:
        break
      }
    }
    return merged
  }
}
