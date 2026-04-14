import ComposableArchitecture
import Foundation
import IdentifiedCollections

/// Where the new terminal session's working directory comes from.
nonisolated enum WorktreeMode: String, CaseIterable, Equatable, Sendable, Identifiable {
  /// Run at the repo root (directory mode). No new worktree created.
  case none
  /// Create a new git worktree branched from HEAD for this session.
  case newBranch
  /// Attach the session to an existing worktree already registered in
  /// the repo.
  case existing

  var id: String { rawValue }

  var label: String {
    switch self {
    case .none: "None"
    case .newBranch: "New"
    case .existing: "Existing"
    }
  }
}

/// Sheet reducer for "+ New Terminal". Collects prompt, repo, agent, and an
/// optional worktree toggle. On submit:
///  1. Resolves the backing workspace (repo root for directory mode, or
///     creates a git worktree for worktree mode).
///  2. Asks TerminalClient to spawn a new tab running `claude "<prompt>"`
///     or `codex "<prompt>"` in that workspace.
///  3. Constructs the `AgentSession` and hands it back to the parent via
///     `delegate(.created(session))`.
@Reducer
struct NewTerminalFeature {
  @ObservableState
  struct State: Equatable {
    let availableRepositories: IdentifiedArrayOf<Repository>
    var selectedRepositoryID: Repository.ID?
    var prompt: String = ""
    /// `nil` = raw shell session (no agent CLI invoked).
    var agent: AgentType? = .claude
    /// Where the agent's terminal should run: repo root (None), a freshly
    /// created git worktree (New), or an already-existing worktree picked
    /// from the repo (Existing).
    var worktreeMode: WorktreeMode = .none
    /// Only consulted when `worktreeMode == .newBranch`.
    var branchName: String = ""
    /// Only consulted when `worktreeMode == .existing`. Defaults to the
    /// first non-root worktree when the repo picker changes.
    var existingWorktreeID: String?
    var validationMessage: String?
    var isCreating: Bool = false

    init(availableRepositories: IdentifiedArrayOf<Repository>) {
      self.availableRepositories = availableRepositories
      selectedRepositoryID = availableRepositories.first?.id
    }

    /// Constructor for "rerun": pre-fills the sheet with values from an
    /// existing session so the user can relaunch the same prompt with
    /// optional tweaks.
    init(
      availableRepositories: IdentifiedArrayOf<Repository>,
      rerunFrom previous: AgentSession
    ) {
      self.availableRepositories = availableRepositories
      selectedRepositoryID = availableRepositories[id: previous.repositoryID]?.id
        ?? availableRepositories.first?.id
      prompt = previous.initialPrompt
      agent = previous.agent
    }
  }

  enum Action: BindableAction, Equatable {
    case binding(BindingAction<State>)
    case cancelButtonTapped
    case createButtonTapped
    case setValidationMessage(String?)
    case setCreating(Bool)
    case sessionReady(AgentSession)
    case creationFailed(message: String)
    case delegate(Delegate)

    @CasePathable
    enum Delegate: Equatable {
      case cancel
      case created(AgentSession)
    }
  }

  @Dependency(GitClientDependency.self) var gitClient
  @Dependency(TerminalClient.self) var terminalClient

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
        let trimmedPrompt = state.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let repoID = state.selectedRepositoryID,
          let repository = state.availableRepositories[id: repoID]
        else {
          state.validationMessage = "Pick a repository."
          return .none
        }
        switch state.worktreeMode {
        case .none:
          break
        case .newBranch:
          let trimmedBranch = state.branchName.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !trimmedBranch.isEmpty else {
            state.validationMessage = "Branch name required."
            return .none
          }
          guard !trimmedBranch.contains(where: \.isWhitespace) else {
            state.validationMessage = "Branch names can't contain spaces."
            return .none
          }
        case .existing:
          guard let worktreeID = state.existingWorktreeID,
            repository.worktrees.contains(where: { $0.id == worktreeID })
          else {
            state.validationMessage = "Pick an existing worktree."
            return .none
          }
        }
        state.validationMessage = nil
        state.isCreating = true

        let worktreeMode = state.worktreeMode
        let branchName = state.branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingWorktreeID = state.existingWorktreeID
        let agent = state.agent
        // The UI toggle is an @AppStorage-backed mirror of this key; read it
        // fresh here so the reducer stays free of view-owned state.
        let bypassPermissions =
          UserDefaults.standard.object(forKey: "supacool.bypassPermissions") as? Bool ?? true
        let sessionID = UUID()
        let gitClient = self.gitClient
        let terminalClient = self.terminalClient

        return .run { send in
          do {
            let worktree: Worktree
            switch worktreeMode {
            case .newBranch:
              let baseRef = await gitClient.automaticWorktreeBaseRef(repository.rootURL) ?? "HEAD"
              let baseDirectory = SupacodePaths.worktreeBaseDirectory(
                for: repository.rootURL,
                globalDefaultPath: nil,
                repositoryOverridePath: nil
              )
              worktree = try await gitClient.createWorktree(
                branchName,
                repository.rootURL,
                baseDirectory,
                false,
                false,
                baseRef
              )
            case .existing:
              // Pinned by the sheet's picker. If the record vanished
              // between picker-time and submit we bail. `Identifiable`
              // on Worktree is @MainActor-isolated, so do the lookup
              // there.
              let picked: Worktree? = await MainActor.run {
                guard let id = existingWorktreeID else { return nil }
                return repository.worktrees.first { $0.id == id }
              }
              guard let picked else { throw NewTerminalError.worktreeMissing }
              worktree = picked
            case .none:
              // Directory mode: resolve the repo-root worktree (guaranteed to
              // exist after Phase 3c), or synthesize one if discovery hasn't
              // caught up yet.
              let rootURL = repository.rootURL.standardizedFileURL
              worktree = await MainActor.run {
                let existing = repository.worktrees.first { wt in
                  wt.workingDirectory == rootURL
                }
                return existing
                  ?? Worktree(
                    id: rootURL.path(percentEncoded: false),
                    name: repository.name,
                    detail: "",
                    workingDirectory: rootURL,
                    repositoryRootURL: rootURL
                  )
              }
            }

            // Spawn the tab, using sessionID as the tab ID so the
            // AgentSession can reference it later. Three cases:
            //   • Agent + prompt → `<agent> "<prompt>"\r`
            //   • Agent, no prompt → `<agent>\r`
            //   • No agent + prompt → type prompt as a shell command + \r
            //   • No agent, no prompt → empty tab, user interacts freely
            let input: String
            switch (agent, trimmedPrompt.isEmpty) {
            case (let agent?, false):
              input = agent.command(prompt: trimmedPrompt, bypassPermissions: bypassPermissions) + "\r"
            case (let agent?, true):
              input = agent.commandWithoutPrompt(bypassPermissions: bypassPermissions) + "\r"
            case (nil, false):
              input = trimmedPrompt + "\r"
            case (nil, true):
              input = ""
            }
            await terminalClient.send(
              .createTabWithInput(
                worktree,
                input: input,
                // Run the repo's setup script (Settings → Repository Settings →
                // Setup Script) before the agent command. `createTab` writes
                // `setupInput + commandInput` to the pty in order, so the
                // setup runs first and the agent launches into the prepared
                // worktree (env files, deps, etc.). Resume paths keep this
                // `false` — their worktree is already initialized.
                runSetupScriptIfNew: true,
                id: sessionID
              )
            )

            let session = AgentSession(
              id: sessionID,
              repositoryID: repository.id,
              worktreeID: worktree.id,
              agent: agent,
              initialPrompt: trimmedPrompt
            )
            await send(.sessionReady(session))
          } catch {
            await send(.creationFailed(message: error.localizedDescription))
          }
        }

      case .setValidationMessage(let message):
        state.validationMessage = message
        return .none

      case .setCreating(let creating):
        state.isCreating = creating
        return .none

      case .sessionReady(let session):
        state.isCreating = false
        return .send(.delegate(.created(session)))

      case .creationFailed(let message):
        state.isCreating = false
        state.validationMessage = message
        return .none

      case .delegate:
        return .none
      }
    }
  }
}

/// Error surfaced from the create effect when the state snapshot taken at
/// submit-time no longer matches reality (e.g. the picked existing
/// worktree was removed between picker-time and submit).
nonisolated enum NewTerminalError: LocalizedError {
  case worktreeMissing

  var errorDescription: String? {
    switch self {
    case .worktreeMissing: "Picked worktree is no longer available."
    }
  }
}
