import ComposableArchitecture
import Foundation

/// Sheet reducer for "Debug this session…" — collects a free-text
/// observation from the user and asks BoardFeature to spawn a fresh
/// Supacool-repo agent session that's primed with the trace + prompt.
///
/// This reducer is deliberately tiny: it doesn't know how to spawn,
/// where supacool lives, or what the prompt template looks like. Those
/// concerns live in `SupacoolDebugSupport` and `BoardFeature`. The
/// sheet only owns the observation field, the submit / cancel
/// gestures, and the structural switch between "registered" and
/// "supacool repo missing" modes.
@Reducer
struct DebugSessionFeature {
  @ObservableState
  struct State: Equatable {
    /// Session being debugged. Snapshot is captured at sheet-open
    /// time so even if the source session is removed mid-edit the
    /// debug spawn still has everything it needs.
    let sourceSession: AgentSession
    /// `false` when no registered repo carries `supacool.xcodeproj` at
    /// its root. When false, the view drops the editor and Spawn
    /// button entirely and shows a "register supacool first" panel.
    var isSupacoolRepoRegistered: Bool = true
    var observation: String = ""
    /// Inline error shown below the editor for transient validation
    /// (empty observation, etc.). Cleared on next edit.
    var errorMessage: String?
  }

  enum Action: BindableAction, Equatable {
    case binding(BindingAction<State>)
    case spawnTapped
    case cancelTapped
    case registerSupacoolTapped
    case delegate(Delegate)

    @CasePathable
    enum Delegate: Equatable {
      case spawnRequested(observation: String, sourceSession: AgentSession)
      case registerSupacoolRequested
      case cancelled
    }
  }

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        // Edits clear any prior validation message so the user sees
        // their next attempt as fresh.
        state.errorMessage = nil
        return .none

      case .spawnTapped:
        let trimmed = state.observation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
          state.errorMessage = "Type what you noticed before spawning a debug session."
          return .none
        }
        return .send(
          .delegate(.spawnRequested(observation: trimmed, sourceSession: state.sourceSession))
        )

      case .cancelTapped:
        return .send(.delegate(.cancelled))

      case .registerSupacoolTapped:
        return .send(.delegate(.registerSupacoolRequested))

      case .delegate:
        return .none
      }
    }
  }
}
