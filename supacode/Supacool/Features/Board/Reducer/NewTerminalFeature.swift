import ComposableArchitecture
import Foundation
import IdentifiedCollections

private nonisolated let newTerminalLogger = SupaLogger("Supacool.NewTerminal")

/// Where the new terminal session will run. Replaces the old trio of
/// (worktreeMode, branchName, existingWorktreeID) with a single enum that
/// unifies directory mode, existing worktrees, existing local/remote
/// branches, and brand-new branches under one workspace picker.
nonisolated enum WorkspaceSelection: Equatable, Hashable, Sendable {
  /// Run at the repo root (no worktree).
  case repoRoot
  /// Attach to an already-registered worktree.
  case existingWorktree(id: String)
  /// Check out an existing local branch in a new worktree. For branches
  /// that only exist on a remote, git's `worktree add` DWIM automatically
  /// creates a local tracking branch.
  case existingBranch(name: String)
  /// Create a new branch from HEAD in a new worktree.
  case newBranch(name: String)
}

/// Sheet reducer for "+ New Terminal". Collects prompt, repo, agent, and
/// a unified workspace choice (repo root / worktree / branch / new branch).
/// On submit:
///  1. Resolves the backing workspace (existing worktree, or creates one).
///  2. Asks TerminalClient to spawn a tab running the agent.
///  3. Constructs the `AgentSession` and hands it back via
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

    // MARK: - Workspace picker

    /// The resolved workspace to run the session in. Kept in sync with
    /// `workspaceQuery` on every keystroke via `inferSelection`.
    var selectedWorkspace: WorkspaceSelection = .repoRoot
    /// The free-text query the user types into the workspace field.
    /// Empty = repo root (directory mode).
    var workspaceQuery: String = ""
    /// Loaded lazily on `.task`. Local branch names (e.g. `["main", "feat-x"]`).
    var availableLocalBranches: [String] = []
    /// Loaded lazily on `.task`. Remote tracking refs (e.g. `["origin/main", "origin/feat-x"]`).
    var availableRemoteBranches: [String] = []
    var isLoadingBranches: Bool = false

    // MARK: - Misc

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

      // Restore the workspace so rerun lands in the same context.
      //
      // worktreeID == repositoryID → session ran at the repo root.
      // Otherwise a dedicated worktree was used. If it still exists, rerun
      // there; if it's gone (cleaned up) pre-fill a .newBranch with the
      // same branch name so the user can recreate it with one tap.
      let worktreeID = previous.worktreeID
      let repoRootID = previous.repositoryID
      if worktreeID != repoRootID,
        let repo = availableRepositories.first(where: { $0.id == resolvedRepoID })
      {
        if let wt = repo.worktrees.first(where: { $0.id == worktreeID }) {
          selectedWorkspace = .existingWorktree(id: worktreeID)
          workspaceQuery = wt.branch ?? wt.name
        } else {
          let derived = URL(fileURLWithPath: worktreeID).lastPathComponent
          selectedWorkspace = .newBranch(name: derived)
          workspaceQuery = derived
        }
      }
      // else: repo root — selectedWorkspace stays .repoRoot
    }
  }

  enum Action: BindableAction, Equatable {
    case binding(BindingAction<State>)
    case task
    case branchesLoaded(local: [String], remote: [String])
    case workspaceSelected(WorkspaceSelection)
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
    case loadBranches
  }

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding(\.workspaceQuery):
        // Typing in the workspace field re-infers the selection from the
        // current query + known worktrees/branches. Exact matches win;
        // otherwise we treat the query as a new branch name.
        state.selectedWorkspace = Self.inferSelection(
          from: state.workspaceQuery,
          state: state
        )
        state.validationMessage = nil
        return .none

      case .binding(\.selectedRepositoryID):
        // Reload the branch list whenever the repo changes.
        state.validationMessage = nil
        state.selectedWorkspace = .repoRoot
        state.workspaceQuery = ""
        state.availableLocalBranches = []
        state.availableRemoteBranches = []
        return .send(.task)

      case .binding:
        state.validationMessage = nil
        return .none

      case .task:
        guard let repoID = state.selectedRepositoryID,
          let repo = state.availableRepositories[id: repoID]
        else { return .none }
        state.isLoadingBranches = true
        let repoRoot = repo.rootURL
        return .run { [gitClient] send in
          async let localTask = (try? await gitClient.localBranchNames(repoRoot)) ?? []
          async let remoteTask = (try? await gitClient.remoteBranchRefs(repoRoot)) ?? []
          let localSet = await localTask
          let remoteList = await remoteTask
          let sortedLocal =
            localSet
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
          await send(.branchesLoaded(local: sortedLocal, remote: remoteList))
        }
        .cancellable(id: CancelID.loadBranches, cancelInFlight: true)

      case .branchesLoaded(let local, let remote):
        state.availableLocalBranches = local
        state.availableRemoteBranches = remote
        state.isLoadingBranches = false
        // Re-run inference now that we have fresh data — query may have
        // matched only after branches loaded.
        state.selectedWorkspace = Self.inferSelection(
          from: state.workspaceQuery,
          state: state
        )
        return .none

      case .workspaceSelected(let selection):
        state.selectedWorkspace = selection
        state.workspaceQuery = Self.canonicalQuery(for: selection, state: state)
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
        state.workspaceQuery = name
        state.selectedWorkspace = Self.inferSelection(from: name, state: state)
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

        let selection = state.selectedWorkspace
        switch selection {
        case .repoRoot:
          break
        case .existingWorktree(let id):
          guard repository.worktrees.contains(where: { $0.id == id }) else {
            state.validationMessage = "Picked worktree no longer exists."
            return .none
          }
        case .existingBranch(let name):
          let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !trimmed.isEmpty else {
            state.validationMessage = "Pick a branch."
            return .none
          }
          guard !trimmed.contains(where: \.isWhitespace) else {
            state.validationMessage = "Branch names can't contain spaces."
            return .none
          }
        case .newBranch(let name):
          let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !trimmed.isEmpty else {
            state.validationMessage = "Branch name required."
            return .none
          }
          guard !trimmed.contains(where: \.isWhitespace) else {
            state.validationMessage = "Branch names can't contain spaces."
            return .none
          }
        }
        if state.agent != nil && trimmedPrompt.isEmpty {
          state.validationMessage = "Prompt required."
          return .none
        }
        state.validationMessage = nil
        state.isCreating = true

        let agent = state.agent
        // Mirror supacode's sidebar flow: obey the global "Fetch origin
        // before creating worktree" toggle so both paths behave the same.
        @Shared(.settingsFile) var settingsFile
        let fetchOriginBeforeCreation = settingsFile.global.fetchOriginBeforeWorktreeCreation
        let bypassPermissions =
          UserDefaults.standard.object(forKey: "supacool.bypassPermissions") as? Bool ?? true
        let sessionID = UUID()
        let gitClient = self.gitClient
        let terminalClient = self.terminalClient

        return .run { send in
          do {
            let worktree: Worktree
            switch selection {
            case .newBranch(let rawName):
              let branchName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
              let baseRef = await gitClient.automaticWorktreeBaseRef(repository.rootURL) ?? "HEAD"
              // Pre-worktree fetch so the new branch is based on the
              // *actually* latest upstream, not the local cache. Failures
              // log but don't block — an offline/auth-broken fetch
              // shouldn't lose the user their prompt.
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

            case .existingBranch(let rawName):
              let branchName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
              // Fetch the matching remote first so DWIM can find freshly
              // pushed branches (e.g. a new PR). Same fetch semantics as
              // .newBranch above.
              if fetchOriginBeforeCreation {
                let remotes = (try? await gitClient.remoteNames(repository.rootURL)) ?? []
                if let firstRemote = remotes.first {
                  do {
                    try await gitClient.fetchRemote(firstRemote, repository.rootURL)
                  } catch {
                    newTerminalLogger.warning(
                      "Pre-worktree fetch \(firstRemote) failed for "
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
              worktree = try await gitClient.createWorktreeForExistingBranch(
                branchName,
                repository.rootURL,
                baseDirectory
              )

            case .existingWorktree(let id):
              // Pinned by the sheet's picker. If the record vanished
              // between picker-time and submit we bail. `Identifiable`
              // on Worktree is @MainActor-isolated, so do the lookup there.
              let picked: Worktree? = await MainActor.run {
                repository.worktrees.first { $0.id == id }
              }
              guard let picked else { throw NewTerminalError.worktreeMissing }
              worktree = picked

            case .repoRoot:
              // Directory mode: resolve the repo-root worktree, or
              // synthesize one if discovery hasn't caught up yet.
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
            // AgentSession can reference it later.
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
                // Setup Script) before the agent command.
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

  // MARK: - Selection inference

  /// Given a free-text query, figure out what workspace the user means.
  /// Exact matches (worktree > local branch > remote branch) win;
  /// otherwise it's a new-branch candidate. Empty query = repo root.
  static func inferSelection(from rawQuery: String, state: State) -> WorkspaceSelection {
    let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return .repoRoot }

    // 1) Existing worktree (match against branch or name).
    if let repoID = state.selectedRepositoryID,
      let repo = state.availableRepositories[id: repoID]
    {
      if let wt = repo.worktrees.first(where: { ($0.branch ?? $0.name) == trimmed && $0.isWorktree }) {
        return .existingWorktree(id: wt.id)
      }
    }
    // 2) Existing local branch.
    if state.availableLocalBranches.contains(trimmed) {
      return .existingBranch(name: trimmed)
    }
    // 3) Full remote ref match (e.g. typed "origin/feat-x").
    if state.availableRemoteBranches.contains(trimmed) {
      return .existingBranch(name: stripRemotePrefix(trimmed))
    }
    // 4) Short name matches a remote branch's local-part (e.g. "feat-x" → "origin/feat-x").
    if state.availableRemoteBranches.contains(where: { stripRemotePrefix($0) == trimmed }) {
      return .existingBranch(name: trimmed)
    }
    // 5) Fallback: new branch.
    return .newBranch(name: trimmed)
  }

  /// Canonical text to display in the query field for a given selection.
  static func canonicalQuery(for selection: WorkspaceSelection, state: State) -> String {
    switch selection {
    case .repoRoot:
      return ""
    case .existingWorktree(let id):
      if let repoID = state.selectedRepositoryID,
        let repo = state.availableRepositories[id: repoID],
        let wt = repo.worktrees.first(where: { $0.id == id })
      {
        return wt.branch ?? wt.name
      }
      return URL(fileURLWithPath: id).lastPathComponent
    case .existingBranch(let name), .newBranch(let name):
      return name
    }
  }

  static func stripRemotePrefix(_ ref: String) -> String {
    if let slashIdx = ref.firstIndex(of: "/") {
      return String(ref[ref.index(after: slashIdx)...])
    }
    return ref
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
