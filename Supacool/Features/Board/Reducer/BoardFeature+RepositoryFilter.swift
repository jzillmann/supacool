import ComposableArchitecture
import Foundation

/// Where the user is looking: a full-screen session, or the board itself.
nonisolated enum BoardLocation: Equatable, Sendable {
  case board
  case session(AgentSession.ID)
}

/// Repo-filter switching. Each filter selection remembers the last location
/// (full-screen session or board) the user had under it, so switching
/// projects returns to that spot instead of always the first card.
extension BoardFeature {
  func switchRepositoryFilter(state: inout State, to selection: Set<String>) {
    let previous = state.filters.selectedRepositoryIDs
    state.lastLocationByRepositoryFilter[previous] =
      state.focusedSessionID.map(BoardLocation.session) ?? .board
    state.$filters.withLock { $0.selectedRepositoryIDs = selection }

    switch state.lastLocationByRepositoryFilter[selection] {
    case .board:
      state.focusHistory.removeAll()
      state.focusedSessionID = nil
    case .session(let id) where state.visibleSessions.contains(where: { $0.id == id }):
      state.focusedSessionID = id
    case .session, nil:
      // Nothing usable remembered (first visit, or the card is gone or
      // filtered out). Keep the current location; the view falls back to
      // the first visible card when the focused one left scope.
      break
    }
  }
}
