import ComposableArchitecture
import Foundation

private nonisolated let notesLogger = SupaLogger("Notes")

/// Session notes: terminal output the user pinned via "Pin Selection".
extension BoardFeature {
  func reducePinTerminalSelection(
    state: inout State,
    worktreeID: Worktree.ID,
    tabID: UUID,
    surfaceID: UUID,
    text: String
  ) -> Effect<Action> {
    guard let normalized = SessionNote.normalized(text) else { return .none }
    guard
      let match = Self.sessionTerminal(
        owningTabID: tabID, surfaceID: surfaceID, worktreeID: worktreeID, in: state.sessions)
    else {
      notesLogger.warning("Pin Selection: no session owns tab \(tabID) in \(worktreeID)")
      return .none
    }
    let note = SessionNote(
      id: uuid(),
      text: normalized,
      terminalID: match.terminalID,
      surfaceID: surfaceID,
      createdAt: date.now
    )
    state.$sessions.withLock { sessions in
      guard let index = sessions.firstIndex(where: { $0.id == match.sessionID }) else { return }
      sessions[index].notes.append(note)
    }
    return .none
  }

  func reduceRemoveNote(
    state: inout State,
    sessionID: AgentSession.ID,
    noteID: SessionNote.ID
  ) -> Effect<Action> {
    state.$sessions.withLock { sessions in
      guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
      sessions[index].notes.removeAll { $0.id == noteID }
    }
    return .none
  }

  /// The session and terminal a surface belongs to. An adopted pane is its
  /// own terminal (its id is the surface id); any other surface in a tab —
  /// the agent's own leaf or an ad-hoc split — counts as the tab terminal.
  static func sessionTerminal(
    owningTabID tabID: UUID,
    surfaceID: UUID,
    worktreeID: Worktree.ID,
    in sessions: [AgentSession]
  ) -> (sessionID: AgentSession.ID, terminalID: UUID)? {
    let candidates = sessions.filter { $0.worktreeID == worktreeID }
    for session in candidates {
      if let pane = session.terminals.first(where: { $0.id == surfaceID && $0.hostTabID == tabID }) {
        return (session.id, pane.id)
      }
    }
    for session in candidates where session.terminals.contains(where: { $0.id == tabID }) {
      return (session.id, tabID)
    }
    return nil
  }
}
