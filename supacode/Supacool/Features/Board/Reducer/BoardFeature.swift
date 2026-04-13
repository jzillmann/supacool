import ComposableArchitecture
import Foundation

/// The Matrix Board — the top-level view of agent sessions as cards.
///
/// Owns:
/// - the list of `AgentSession` (persisted to disk)
/// - the repository filter (persisted to disk)
/// - `focusedSessionID`: when non-nil, the UI swaps from board → full-screen
///   terminal for that session. Transient, not persisted.
///
/// Status bucketing (Waiting on Me vs In Progress) is DERIVED at render time
/// from `WorktreeTerminalManager.isTabBusy(tabID:)`; this reducer doesn't
/// track live agent-busy state.
@Reducer
struct BoardFeature {
  @ObservableState
  struct State: Equatable {
    @Shared(.agentSessions) var sessions: [AgentSession] = []
    @Shared(.boardFilters) var filters: BoardFilters = .empty

    /// When non-nil, the root view shows this session's terminal full-screen
    /// instead of the board. Not persisted — fresh launches always land on
    /// the board.
    var focusedSessionID: AgentSession.ID?

    /// The new-terminal sheet state, if open.
    @Presents var newTerminalSheet: NewTerminalFeature.State?
  }

  enum Action: BindableAction, Equatable {
    case binding(BindingAction<State>)

    // MARK: Session CRUD
    case createSession(AgentSession)
    case renameSession(id: AgentSession.ID, newName: String)
    case removeSession(id: AgentSession.ID)
    case markSessionActivity(id: AgentSession.ID)
    case markSessionCompletedOnce(id: AgentSession.ID)

    // MARK: Focus
    case focusSession(id: AgentSession.ID?)

    // MARK: Repo filter
    case toggleRepository(id: String)
    case showAllRepositories

    // MARK: New-terminal sheet
    case openNewTerminalSheet(repositories: [Repository])
    case newTerminalSheet(PresentationAction<NewTerminalFeature.Action>)
  }

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .createSession(let session):
        state.$sessions.withLock { $0.append(session) }
        state.focusedSessionID = session.id
        return .none

      case .renameSession(let id, let newName):
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }
        state.$sessions.withLock { sessions in
          guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
          sessions[index].displayName = trimmed
        }
        return .none

      case .removeSession(let id):
        state.$sessions.withLock { $0.removeAll(where: { $0.id == id }) }
        if state.focusedSessionID == id {
          state.focusedSessionID = nil
        }
        return .none

      case .markSessionActivity(let id):
        state.$sessions.withLock { sessions in
          guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
          sessions[index].lastActivityAt = Date()
        }
        return .none

      case .markSessionCompletedOnce(let id):
        state.$sessions.withLock { sessions in
          guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
          guard !sessions[index].hasCompletedAtLeastOnce else { return }
          sessions[index].hasCompletedAtLeastOnce = true
          sessions[index].lastActivityAt = Date()
        }
        return .none

      case .focusSession(let id):
        state.focusedSessionID = id
        return .none

      case .toggleRepository(let repositoryID):
        state.$filters.withLock { filters in
          if filters.selectedRepositoryIDs.contains(repositoryID) {
            filters.selectedRepositoryIDs.remove(repositoryID)
          } else {
            filters.selectedRepositoryIDs.insert(repositoryID)
          }
        }
        return .none

      case .showAllRepositories:
        state.$filters.withLock { $0.selectedRepositoryIDs = [] }
        return .none

      case .openNewTerminalSheet(let repositories):
        state.newTerminalSheet = NewTerminalFeature.State(
          availableRepositories: IdentifiedArray(uniqueElements: repositories)
        )
        return .none

      case .newTerminalSheet(.presented(.delegate(.created(let session)))):
        state.newTerminalSheet = nil
        return .send(.createSession(session))

      case .newTerminalSheet(.presented(.delegate(.cancel))):
        state.newTerminalSheet = nil
        return .none

      case .newTerminalSheet:
        return .none
      }
    }
    .ifLet(\.$newTerminalSheet, action: \.newTerminalSheet) {
      NewTerminalFeature()
    }
  }
}

// MARK: - Derived queries

extension BoardFeature.State {
  /// Sessions visible under the current repo filter, preserving insertion order.
  var visibleSessions: [AgentSession] {
    sessions.filter { filters.includes(repositoryID: $0.repositoryID) }
  }

  /// Look up a session by ID (O(n), fine for small N).
  func session(id: AgentSession.ID?) -> AgentSession? {
    guard let id else { return nil }
    return sessions.first(where: { $0.id == id })
  }
}

// Real `NewTerminalFeature` lives in
// Supacool/Features/Board/Reducer/NewTerminalFeature.swift
