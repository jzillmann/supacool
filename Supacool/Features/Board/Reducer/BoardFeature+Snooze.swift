import ComposableArchitecture
import Foundation

/// Snooze: park a card with a wake-up time. The park itself reuses the Park /
/// Standby reducers; this file only adds the deadline and the ticker that
/// honors it.
extension BoardFeature {
  /// How often the wake ticker checks deadlines. Snooze presets are hours or
  /// days apart, so a minute of slack is invisible.
  nonisolated static let snoozeWakeInterval: Duration = .seconds(60)

  func reduceSnoozeSession(
    state: inout State,
    id: AgentSession.ID,
    option: SnoozeOption,
    keepAlive: Bool,
    repositories: [Repository]
  ) -> Effect<Action> {
    guard state.sessions.contains(where: { $0.id == id }) else { return .none }
    let parkEffect =
      keepAlive
      ? reduceParkActiveSession(state: &state, id: id)
      : reduceParkSession(state: &state, id: id, repositories: repositories)
    // Set after parking: both park reducers reset the deadline.
    let wakeAt = option.wakeDate(from: date.now)
    state.$sessions.withLock { sessions in
      guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
      sessions[index].parkedUntil = wakeAt
    }
    return parkEffect
  }

  func reduceWakeSnoozedSessions(state: inout State) -> Effect<Action> {
    let now = date.now
    let due = state.sessions.filter { session in
      guard session.parked, let wakeAt = session.parkedUntil else { return false }
      return wakeAt <= now
    }
    guard !due.isEmpty else { return .none }
    let dueIDs = Set(due.map(\.id))
    state.$sessions.withLock { sessions in
      for index in sessions.indices where dueIDs.contains(sessions[index].id) {
        sessions[index].parked = false
        sessions[index].parkedActive = false
        sessions[index].parkedUntil = nil
        // Priority is what makes it "jump back": it sorts first in its bucket
        // and keeps a woken idle card out of the collapsed frozen deck.
        sessions[index].isPriority = true
        sessions[index].updatePrimaryTerminal { $0.lastActivityAt = now }
      }
    }
    var effects: [Effect<Action>] = []
    for session in due {
      TranscriptRecorder.shared.append(
        event: .sessionLifecycle(kind: "unparked", context: "snooze", at: now),
        tabID: TerminalTabID(rawValue: session.id)
      )
      // Only a Standby session still has its terminal, so only it gets the
      // dev server back. A cold-parked card wakes idle and starts nothing
      // until the user resumes it.
      if session.parkedActive {
        effects.append(prepareAutoStartLifecycleEffect(&state, session: session))
      }
    }
    return .merge(effects)
  }

  /// Checks once right away (a deadline may have passed while the app was
  /// quit), then every `snoozeWakeInterval`.
  func snoozeWakeTicker() -> Effect<Action> {
    .run { [clock] send in
      await send(._wakeSnoozedSessions)
      while !Task.isCancelled {
        do {
          try await clock.sleep(for: Self.snoozeWakeInterval)
        } catch {
          return
        }
        await send(._wakeSnoozedSessions)
      }
    }
    .cancellable(id: SnoozeWakeTickerCancelID(), cancelInFlight: true)
  }
}

private nonisolated struct SnoozeWakeTickerCancelID: Hashable, Sendable {}
