import ComposableArchitecture
import Foundation

nonisolated enum WorkspaceMode: String, CaseIterable, Equatable, Sendable {
  case directory
  case newWorktree
  case existingWorktree
}

@Reducer
struct WorktreeCreationPromptFeature {
  @ObservableState
  struct State: Equatable {
    let repositoryID: Repository.ID
    let repositoryName: String
    let repositoryRootURL: URL
    let automaticBaseRef: String
    let baseRefOptions: [String]
    let availableWorktrees: [Worktree]
    var mode: WorkspaceMode = .directory
    var branchName: String
    var selectedBaseRef: String?
    var selectedExistingWorktreeID: Worktree.ID?
    var fetchOrigin: Bool
    var validationMessage: String?
    var isValidating = false
  }

  enum Action: BindableAction, Equatable {
    case binding(BindingAction<State>)
    case cancelButtonTapped
    case createButtonTapped
    case setValidationMessage(String?)
    case setValidating(Bool)
    case delegate(Delegate)
  }

  @CasePathable
  enum Delegate: Equatable {
    case cancel
    case submit(repositoryID: Repository.ID, branchName: String, baseRef: String?, fetchOrigin: Bool)
    case submitExistingWorktree(repositoryID: Repository.ID, worktreeID: Worktree.ID)
    case submitDirectory(repositoryID: Repository.ID, path: URL)
  }

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        state.validationMessage = nil
        return .none

      case .cancelButtonTapped:
        return .send(.delegate(.cancel))

      case .createButtonTapped:
        switch state.mode {
        case .newWorktree:
          let trimmed = state.branchName.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !trimmed.isEmpty else {
            state.validationMessage = "Branch name required."
            return .none
          }
          guard !trimmed.contains(where: \.isWhitespace) else {
            state.validationMessage = "Branch names can't contain spaces."
            return .none
          }
          state.validationMessage = nil
          return .send(
            .delegate(
              .submit(
                repositoryID: state.repositoryID,
                branchName: trimmed,
                baseRef: state.selectedBaseRef,
                fetchOrigin: state.fetchOrigin
              )
            )
          )

        case .existingWorktree:
          guard let worktreeID = state.selectedExistingWorktreeID else {
            state.validationMessage = "Select a worktree."
            return .none
          }
          state.validationMessage = nil
          return .send(
            .delegate(
              .submitExistingWorktree(
                repositoryID: state.repositoryID,
                worktreeID: worktreeID
              )
            )
          )

        case .directory:
          return .send(
            .delegate(
              .submitDirectory(
                repositoryID: state.repositoryID,
                path: state.repositoryRootURL
              )
            )
          )
        }

      case .setValidationMessage(let message):
        state.validationMessage = message
        return .none

      case .setValidating(let isValidating):
        state.isValidating = isValidating
        return .none

      case .delegate:
        return .none
      }
    }
  }
}
