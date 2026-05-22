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
/// Where the debug agent runs. `.main` reuses the supacool repo root
/// (no worktree created); `.worktree` carves a fresh worktree off HEAD
/// using the user-editable branch name in `State.branchName`.
nonisolated enum DebugTarget: String, CaseIterable, Identifiable, Equatable, Sendable {
  case main
  case worktree
  var id: String { rawValue }
  var displayName: String {
    switch self {
    case .main: return "Main"
    case .worktree: return "Worktree"
    }
  }
}

/// What kind of thing we're asking the debug agent to look at. Either a
/// real `AgentSession` (the "Debug session…" right-click on a card) or
/// a `sessionSpawnFailed` tray-card error (no AgentSession ever existed
/// because the spawn itself failed). The spawn handler in BoardFeature
/// branches on this to pick the right prompt template + display name.
nonisolated enum DebugSource: Equatable, Sendable {
  case session(AgentSession)
  case spawnFailure(errorTitle: String, errorMessage: String)

  /// Short label shown in the sheet header and used to seed the
  /// auto-generated worktree branch name.
  var displayName: String {
    switch self {
    case .session(let session): return session.displayName
    case .spawnFailure(let title, _): return title
    }
  }
}

@Reducer
struct DebugSessionFeature {
  @ObservableState
  struct State: Equatable {
    /// What we're debugging. Snapshot is captured at sheet-open time
    /// so even if the source session/card is removed mid-edit the
    /// debug spawn still has everything it needs.
    let source: DebugSource
    /// `false` when no registered repo carries `supacool.xcodeproj` at
    /// its root. When false, the view drops the editor and Spawn
    /// button entirely and shows a "register supacool first" panel.
    var isSupacoolRepoRegistered: Bool = true
    /// Agent to spawn for the debug session. Defaults to Claude — it has
    /// the strongest tool surface for the read-trace + propose-fix flow,
    /// and matches what early debug sessions shipped with. Picker in the
    /// sheet lets the user override (pi / codex / user-defined).
    var agent: AgentType = .claude
    /// Run on the supacool repo root vs. a fresh worktree. Defaults to
    /// `.worktree` to preserve the previous behaviour (every debug spawn
    /// got its own branch); the picker lets the user opt into running
    /// directly on the main checkout when they don't want the churn.
    var target: DebugTarget = .worktree
    /// Auto-generated `debug_<slug>_<HHmm>` name shown when `target` is
    /// `.worktree`. Editable so the user can rename before spawning.
    var branchName: String = ""
    var observation: String = ""
    /// Inline error shown below the editor for transient validation
    /// (empty observation, etc.). Cleared on next edit.
    var errorMessage: String?

    init(source: DebugSource) {
      self.source = source
      self.branchName = SupacoolDebugSupport.debugWorktreeName(
        sourceDisplayName: source.displayName
      )
      // For spawn-failure sources, seed the observation with the error
      // message so the user has something concrete to edit or extend
      // instead of staring at an empty editor. Real sessions start
      // blank — the user types what they noticed in the source's
      // behaviour, which is the whole point of the editor.
      if case .spawnFailure(let title, let message) = source {
        self.observation = "Couldn't spawn \"\(title)\". Error:\n\(message)"
      }
    }

    /// Convenience initializer kept for call sites that already had a
    /// real `AgentSession` (the "Debug session…" card menu).
    init(sourceSession: AgentSession) {
      self.init(source: .session(sourceSession))
    }
  }

  enum Action: BindableAction, Equatable {
    case binding(BindingAction<State>)
    case spawnTapped
    case cancelTapped
    case registerSupacoolTapped
    case delegate(Delegate)

    @CasePathable
    enum Delegate: Equatable {
      case spawnRequested(
        observation: String,
        agent: AgentType,
        selection: WorkspaceSelection,
        source: DebugSource
      )
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
        let selection: WorkspaceSelection
        switch state.target {
        case .main:
          selection = .repoRoot
        case .worktree:
          let trimmedBranch = state.branchName.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !trimmedBranch.isEmpty else {
            state.errorMessage = "Worktree branch name can't be empty."
            return .none
          }
          selection = .newBranch(name: trimmedBranch)
        }
        return .send(
          .delegate(
            .spawnRequested(
              observation: trimmed,
              agent: state.agent,
              selection: selection,
              source: state.source
            )
          )
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
