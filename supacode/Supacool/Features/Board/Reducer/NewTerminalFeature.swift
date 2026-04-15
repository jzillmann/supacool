import ComposableArchitecture
import Foundation
import IdentifiedCollections

private nonisolated let newTerminalLogger = SupaLogger("Supacool.NewTerminal")

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
    /// True while the background inference client is generating a branch name.
    var isSuggestingBranchName: Bool = false

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
      let resolvedRepoID = availableRepositories[id: previous.repositoryID]?.id
        ?? availableRepositories.first?.id
      selectedRepositoryID = resolvedRepoID
      prompt = previous.initialPrompt
      agent = previous.agent

      // Restore the worktree mode so rerun lands in the same workspace context.
      //
      // worktreeID == repositoryID → session ran at the repo root → mode .none.
      // Otherwise a dedicated worktree was used. If it still exists in the repo
      // use .existing so the user reruns in the exact same directory; if it's
      // gone (cleaned up) pre-fill .newBranch with the same branch name so the
      // user can recreate it with one tap.
      let worktreeID = previous.worktreeID
      let repoRootID = previous.repositoryID
      if worktreeID != repoRootID,
        let repo = availableRepositories.first(where: { $0.id == resolvedRepoID })
      {
        if repo.worktrees.contains(where: { $0.id == worktreeID }) {
          worktreeMode = .existing
          existingWorktreeID = worktreeID
        } else {
          worktreeMode = .newBranch
          branchName = URL(fileURLWithPath: worktreeID).lastPathComponent
        }
      }
      // else: worktreeID == repositoryID → worktreeMode stays .none
    }
  }

  enum Action: BindableAction, Equatable {
    case binding(BindingAction<State>)
    case cancelButtonTapped
    case createButtonTapped
    case suggestBranchNameTapped
    case branchNameSuggested(String)
    case branchNameSuggestionFailed
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
  @Dependency(BackgroundInferenceClient.self) var backgroundInferenceClient

  private nonisolated enum CancelID: Hashable, Sendable {
    case branchNameSuggestion
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

      case .suggestBranchNameTapped:
        guard !state.isSuggestingBranchName else { return .none }
        let prompt = state.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return .none }
        state.isSuggestingBranchName = true
        let inferencePrompt =
          "Generate a concise git branch name for this task:\n\n\(prompt)\n\n"
          + "Requirements:\n"
          + "- Use kebab-case (lowercase, hyphens between words)\n"
          + "- Maximum 40 characters\n"
          + "- No spaces or special characters\n"
          + "Reply with ONLY the branch name, nothing else."
        return .run { [backgroundInferenceClient] send in
          do {
            let raw = try await backgroundInferenceClient.infer(inferencePrompt)
            let name = sanitizeBranchName(raw)
            await send(.branchNameSuggested(name.isEmpty ? raw : name))
          } catch {
            newTerminalLogger.warning("Branch name suggestion failed: \(error)")
            await send(.branchNameSuggestionFailed)
          }
        }
        .cancellable(id: CancelID.branchNameSuggestion, cancelInFlight: true)

      case .branchNameSuggested(let name):
        state.isSuggestingBranchName = false
        state.branchName = name
        return .none

      case .branchNameSuggestionFailed:
        state.isSuggestingBranchName = false
        return .none

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
        if state.agent != nil && trimmedPrompt.isEmpty {
          state.validationMessage = "Prompt required."
          return .none
        }
        state.validationMessage = nil
        state.isCreating = true

        let worktreeMode = state.worktreeMode
        let branchName = state.branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingWorktreeID = state.existingWorktreeID
        let agent = state.agent
        // Mirror supacode's sidebar flow: obey the global "Fetch origin
        // before creating worktree" toggle so both paths behave the same.
        @Shared(.settingsFile) var settingsFile
        let fetchOriginBeforeCreation = settingsFile.global.fetchOriginBeforeWorktreeCreation
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
              // Pre-worktree fetch so the new branch is based on the
              // *actually* latest upstream, not the local cache. Upstream
              // supacode's sidebar flow (RepositoriesFeature) does this
              // via remoteNames + matchingRemote + fetchRemote; mirror it.
              // Failures are logged but don't block session creation —
              // an offline / auth-broken fetch shouldn't lose the user
              // their prompt.
              if fetchOriginBeforeCreation {
                let remotes = (try? await gitClient.remoteNames(repository.rootURL)) ?? []
                if let matchedRemote = baseRef.supacoolMatchingRemote(from: remotes) {
                  do {
                    try await gitClient.fetchRemote(matchedRemote, repository.rootURL)
                  } catch {
                    newTerminalLogger.warning(
                      "Pre-worktree fetch \(matchedRemote) failed for "
                        + "\(repository.rootURL.path(percentEncoded: false)): \(error)"
                    )
                  }
                }
              }
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

extension String {
  /// Returns the remote name if this ref starts with `<remote>/`, matched
  /// against known remotes. Longest-match wins to handle ambiguous
  /// prefixes (e.g. `origin` vs `origin-mirror`). Named distinctly from
  /// upstream supacode's `matchingRemote` to avoid collisions on future
  /// upstream syncs.
  fileprivate nonisolated func supacoolMatchingRemote(from remotes: [String]) -> String? {
    remotes.sorted { $0.count > $1.count }.first { hasPrefix("\($0)/") }
  }
}
