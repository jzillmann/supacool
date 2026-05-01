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

/// Tracks the "paste a PR URL to pre-configure the sheet" flow. Set from
/// the prompt field's binding when a GitHub PR URL is detected; resolved
/// asynchronously via `gh pr view`; drives auto-selection of the repo +
/// workspace so the user doesn't need to pick them manually.
nonisolated enum PullRequestLookupState: Equatable, Sendable {
  case idle
  /// gh lookup in flight.
  case fetching(ParsedPullRequestURL)
  /// Successful lookup and a matching local repo was found.
  case resolved(PullRequestContext)
  /// Lookup failed, no configured repo matches, or the PR was from a fork.
  /// Sheet falls back to manual entry; message shown inline.
  case failed(parsed: ParsedPullRequestURL, message: String)
  /// User explicitly dismissed the PR association (via the banner's close
  /// button). The URL is still in the prompt, but we suppress re-fetching
  /// until the user edits it to something different. This lets users paste
  /// logs containing stray PR links without the sheet hijacking their repo
  /// and workspace selection.
  case dismissed(ParsedPullRequestURL)
}

nonisolated struct PullRequestContext: Equatable, Sendable {
  let parsed: ParsedPullRequestURL
  let metadata: SupacoolPRMetadata
  let matchedRepositoryID: Repository.ID
  /// True if the PR's head repo differs from its base repo (i.e. fork PR).
  /// v1 still pre-fills the branch name, but git fetch on origin won't find
  /// it — we surface a warning in the banner so the user knows to check out
  /// the fork branch manually if needed.
  let isFork: Bool
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
  /// Where the new session runs. Local → a worktree inside one of the
  /// configured repositories. Remote → a working directory on an SSH host
  /// from `@Shared(.remoteHosts)`.
  nonisolated enum Destination: Hashable, Sendable {
    case local
    case repositoryRemote(targetID: RepositoryRemoteTarget.ID)
    case remote(hostID: RemoteHost.ID)

    var isRemote: Bool {
      switch self {
      case .local:
        return false
      case .repositoryRemote, .remote:
        return true
      }
    }

    var isManualRemote: Bool {
      if case .remote = self { return true }
      return false
    }
  }

  @ObservableState
  struct State: Equatable {
    let availableRepositories: IdentifiedArrayOf<Repository>
    var selectedRepositoryID: Repository.ID?
    var prompt: String = ""
    /// `nil` = raw shell session (no agent CLI invoked).
    var agent: AgentType? = .claude

    // MARK: - Destination (local vs. remote host)

    var destination: Destination = .local
    /// Absolute remote path — only read when `destination` is `.remote`.
    /// Either matches an existing `RemoteWorkspace` for the chosen host
    /// (we reuse the record) or names a fresh directory (we persist a
    /// new workspace on create).
    var remoteWorkingDirectoryDraft: String = ""
    /// Snapshot of `@Shared(.remoteHosts)` — refreshed on `.task` so the
    /// segmented picker renders without having to put `@Shared` directly
    /// on this struct (which breaks KeyPath Sendability for the
    /// existing `.binding(\.prompt)` cases).
    var availableRemoteHosts: [RemoteHost] = []
    /// Snapshot of `@Shared(.remoteWorkspaces)` — same rationale.
    var availableRemoteWorkspaces: [RemoteWorkspace] = []
    /// Remote launch targets configured on the selected repository.
    /// When non-empty, the destination picker offers "Local" plus these
    /// named remotes so the user chooses the intended target explicitly.
    var availableRepositoryRemoteTargets: [RepositoryRemoteTarget] = []

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
    var planMode: Bool = false
    /// True while the background inference client is generating a branch name.
    var isSuggestingBranchName: Bool = false
    /// If rerun came from a session-owned worktree, preserve ownership only
    /// when the user keeps targeting that same worktree.
    var rerunOwnedWorktreeID: String?

    // MARK: - Bookmarks

    /// True when the user has ticked "Save as bookmark" in the sheet.
    /// On create, the delegate emits `.bookmarkSaved` in addition to
    /// `.created` so BoardFeature can persist the bookmark.
    var saveAsBookmark: Bool = false
    /// User-provided name for the bookmark. Required (trimmed-non-empty)
    /// when `saveAsBookmark` is on.
    var bookmarkName: String = ""
    /// Non-nil when the sheet was opened to edit an existing bookmark.
    /// `bookmarkSaved` preserves this ID so BoardFeature replaces
    /// in-place rather than appending a duplicate.
    var editingBookmarkID: Bookmark.ID?

    // MARK: - Drafts

    /// Non-nil when the sheet was opened from a saved Draft. Two effects:
    /// - `Save Draft` updates the same draft in-place (preserves the ID).
    /// - On successful Create the sheet emits `.draftConsumed(id)` so
    ///   BoardFeature drops the draft from `$drafts` — launching a draft
    ///   "uses it up", matching the inbox-style mental model. To convert
    ///   a draft into a recurring template the user saves a Bookmark
    ///   instead.
    var editingDraftID: Draft.ID?

    // MARK: - PR URL flow

    /// State of the "paste a PR URL into the prompt to pre-configure the
    /// sheet" flow. Driven entirely off the prompt field — no separate
    /// input. Resets to `.idle` when the URL is removed from the prompt.
    var pullRequestLookup: PullRequestLookupState = .idle

    init(
      availableRepositories: IdentifiedArrayOf<Repository>,
      preferredRepositoryID: Repository.ID? = nil
    ) {
      self.availableRepositories = availableRepositories
      selectedRepositoryID =
        preferredRepositoryID.flatMap { availableRepositories[id: $0]?.id }
        ?? availableRepositories.first?.id
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
      planMode = previous.planMode

      if previous.isRemote {
        @Shared(.remoteWorkspaces) var remoteWorkspaces: [RemoteWorkspace]
        if let workspaceID = previous.remoteWorkspaceID,
          let workspace = remoteWorkspaces.first(where: { $0.id == workspaceID })
        {
          remoteWorkingDirectoryDraft = workspace.remoteWorkingDirectory
        }
        if let targetID = previous.repositoryRemoteTargetID {
          destination = .repositoryRemote(targetID: targetID)
        } else if let hostID = previous.remoteHostID {
          destination = .remote(hostID: hostID)
        }
        return
      }

      // Restore the workspace so rerun lands in the same context.
      //
      // currentWorkspacePath == repositoryID → session was running at the
      // repo root when it ended. Otherwise it was in a dedicated worktree
      // (either originally or after a convert-to-worktree flow). If the
      // worktree still exists on the repo, rerun there; if it's gone
      // (cleaned up) pre-fill a .newBranch with the same branch name so
      // the user can recreate it with one tap.
      //
      // Reading `currentWorkspacePath` (not `worktreeID`) so a session
      // that started at repo root and was later converted to a worktree
      // reruns on the worktree, matching what the user last saw.
      let workspaceID = previous.currentWorkspacePath
      let repoRootID = previous.repositoryID
      if workspaceID != repoRootID,
        let repo = availableRepositories.first(where: { $0.id == resolvedRepoID })
      {
        // Only flag "rerun owns the worktree" when the session itself
        // owned its ORIGINAL worktree AND is rerunning on that same one.
        // A session converted to a different worktree mid-life doesn't
        // imply ownership of the new one.
        rerunOwnedWorktreeID =
          (previous.removeBackingWorktreeOnDelete && previous.worktreeID == workspaceID)
          ? workspaceID : nil
        if let wt = repo.worktrees.first(where: { $0.id == workspaceID }) {
          selectedWorkspace = .existingWorktree(id: workspaceID)
          workspaceQuery = wt.branch ?? wt.name
        } else {
          let derived = URL(fileURLWithPath: workspaceID).lastPathComponent
          selectedWorkspace = .newBranch(name: derived)
          workspaceQuery = derived
        }
      }
      // else: repo root — selectedWorkspace stays .repoRoot
    }

    /// Constructor for "graduate to worktree": a repo-root session wants
    /// to spawn a sibling on a fresh worktree so the user can start
    /// making changes without touching the tracked working copy. The
    /// original session keeps running; this one boots blank with the
    /// Worktree segment pre-armed (empty branch name — the user types or
    /// uses the ✨ suggest button).
    init(
      availableRepositories: IdentifiedArrayOf<Repository>,
      graduatingFrom previous: AgentSession
    ) {
      self.availableRepositories = availableRepositories
      selectedRepositoryID = availableRepositories[id: previous.repositoryID]?.id
        ?? availableRepositories.first?.id
      agent = previous.agent
      planMode = previous.planMode
      selectedWorkspace = .newBranch(name: "")
      workspaceQuery = ""
    }

    /// Constructor for "edit an existing bookmark": pre-fills the sheet
    /// from the bookmark and pre-arms the save toggle so submitting
    /// replaces the bookmark in-place (same ID) and also spawns a
    /// session — i.e. "save edits + run once".
    init(
      availableRepositories: IdentifiedArrayOf<Repository>,
      editing bookmark: Bookmark
    ) {
      self.availableRepositories = availableRepositories
      selectedRepositoryID = availableRepositories[id: bookmark.repositoryID]?.id
        ?? availableRepositories.first?.id
      prompt = bookmark.prompt
      agent = bookmark.agent
      planMode = bookmark.planMode
      saveAsBookmark = true
      bookmarkName = bookmark.name
      editingBookmarkID = bookmark.id
      switch bookmark.worktreeMode {
      case .repoRoot:
        selectedWorkspace = .repoRoot
        workspaceQuery = ""
      case .newWorktree:
        // User will pick a fresh name / branch when they submit; the
        // auto-generated bookmark worktree names aren't meaningful
        // here.
        selectedWorkspace = .newBranch(name: "")
        workspaceQuery = ""
      }
    }

    /// Constructor for "resume a saved draft": pre-fills the sheet from a
    /// `Draft` and pins `editingDraftID` so Save Draft updates in-place
    /// and Create consumes the draft. Workspace selection is re-inferred
    /// against the *current* branch list inside `.task` once branches
    /// load — we only seed `workspaceQuery` here.
    init(
      availableRepositories: IdentifiedArrayOf<Repository>,
      resuming draft: Draft
    ) {
      self.availableRepositories = availableRepositories
      let resolvedRepoID =
        draft.repositoryID.flatMap { availableRepositories[id: $0]?.id }
        ?? availableRepositories.first?.id
      selectedRepositoryID = resolvedRepoID
      prompt = draft.prompt
      agent = draft.agent
      planMode = draft.planMode
      workspaceQuery = draft.workspaceQuery
      // Initial best-effort selection inference. The branches list is
      // empty at init time so anything non-empty falls into `.newBranch`,
      // but `branchesLoaded` re-runs inference once the actual branches
      // arrive — at which point an existing-branch / existing-worktree
      // match takes over.
      let trimmed = workspaceQuery.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty {
        selectedWorkspace = .newBranch(name: trimmed)
      }
      editingDraftID = draft.id
    }

    /// Build the Bookmark to persist if the user opted in. Returns nil
    /// when the toggle is off, the name is blank, or there's no repo.
    /// Called from the `.sessionReady` handler so we only persist on
    /// successful session creation.
    func pendingBookmarkToSave(for session: AgentSession) -> Bookmark? {
      guard saveAsBookmark else { return nil }
      let trimmedName = bookmarkName.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmedName.isEmpty else { return nil }
      let worktreeMode: Bookmark.WorktreeMode = {
        switch selectedWorkspace {
        case .repoRoot: return .repoRoot
        case .newBranch, .existingBranch, .existingWorktree: return .newWorktree
        }
      }()
      return Bookmark(
        id: editingBookmarkID ?? UUID(),
        repositoryID: session.repositoryID,
        name: trimmedName,
        prompt: session.initialPrompt,
        agent: session.agent,
        worktreeMode: worktreeMode,
        planMode: session.planMode
      )
    }
  }

  enum Action: BindableAction, Equatable {
    case binding(BindingAction<State>)
    case task
    case branchesLoaded(local: [String], remote: [String])
    case workspaceSelected(WorkspaceSelection)
    case cancelButtonTapped
    case createButtonTapped
    /// User tapped Save Draft — persists the current sheet state as a
    /// `Draft` (without spawning anything) and dismisses the sheet.
    /// Validation is intentionally minimal: we accept blank prompts,
    /// blank workspace queries, etc. The whole point of a draft is that
    /// the user isn't ready to commit yet.
    case saveDraftButtonTapped
    case suggestBranchNameTapped
    case branchNameSuggested(String)
    case branchNameSuggestionFailed
    case setValidationMessage(String?)
    case setCreating(Bool)
    case sessionReady(AgentSession)
    case creationFailed(message: String)
    case pullRequestLookupResolved(PullRequestContext)
    case pullRequestLookupNotMatched(parsed: ParsedPullRequestURL, reason: String)
    case pullRequestLookupFailed(parsed: ParsedPullRequestURL, message: String)
    /// User tapped the banner's close button to drop the PR association
    /// without editing the prompt. Transitions the lookup to `.dismissed`
    /// so subsequent prompt edits that keep the same URL don't re-trigger
    /// the lookup.
    case pullRequestDismissTapped

    /// User flipped the destination segmented picker. `.local` reverts
    /// to the git-backed flow; `.remote(hostID:)` replaces the repo /
    /// workspace pickers with the remote working-directory field.
    case destinationChanged(Destination)
    /// User picked an agent via ⌘0/⌘1/⌘2. Kept as a discrete action so
    /// the shortcut buttons don't mutate store state directly (banned by
    /// the `store_state_mutation_in_views` lint rule) and don't pay the
    /// KeyPath Sendable tax that `.binding(.set(\.agent, _))` would.
    case agentSelected(AgentType?)
    case delegate(Delegate)

    @CasePathable
    enum Delegate: Equatable {
      case cancel
      /// Local-path submit. Sheet dismisses immediately; BoardFeature
      /// owns the spawn so the long-running git/terminal work doesn't
      /// hold the sheet open. `displayName` seeds the placeholder tray
      /// card while the worktree is being created.
      case spawnRequested(SessionSpawner.LocalRequest, displayName: String)
      /// Remote-path completion: spawn happens inside the sheet's
      /// reducer (no worktree creation, fast). Kept for the remote
      /// flow only.
      case created(AgentSession)
      /// Emitted when `saveAsBookmark` was ticked at submit-time.
      /// BoardFeature appends to `$bookmarks` (or replaces in-place
      /// when `editingBookmarkID` is set on the bookmark).
      case bookmarkSaved(Bookmark)
      /// User tapped Save Draft. Carries a fully-populated `Draft` (id
      /// preserved when editing, generated when new). BoardFeature
      /// upserts into `$drafts`.
      case draftSaved(Draft)
      /// Emitted alongside `.created` / `.spawnRequested` when the sheet
      /// was originally opened from a draft. BoardFeature drops the
      /// draft from `$drafts` — launching consumes it.
      case draftConsumed(id: Draft.ID)
    }
  }

  @Dependency(GitClientDependency.self) var gitClient
  @Dependency(TerminalClient.self) var terminalClient
  @Dependency(BackgroundInferenceClient.self) var backgroundInferenceClient
  @Dependency(SupacoolGithubPRClient.self) var supacoolGithubPR
  @Dependency(RemoteSpawnClient.self) var remoteSpawnClient
  @Dependency(SessionReferenceScannerClient.self) var scannerClient
  @Dependency(RepoSyncClient.self) var repoSyncClient

  private nonisolated enum CancelID: Hashable, Sendable {
    case branchNameSuggestion
    case loadBranches
    case pullRequestLookup
  }

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding(\.workspaceQuery):
        // Git refuses branch names containing whitespace. Replace any
        // typed (or pasted) whitespace with hyphens inline so the user
        // never has to see the "can't contain spaces" error — what they
        // see in the field is what will actually be used.
        if state.workspaceQuery.contains(where: \.isWhitespace) {
          state.workspaceQuery = state.workspaceQuery.replacing(/\s+/, with: "-")
        }
        // An empty query used to flip the selection back to `.repoRoot`,
        // which fought the new explicit Investigate/Worktree segmented
        // picker: the user would click Worktree, focus the Workspace
        // field (which re-emits the binding via @Bindable's round-trip),
        // and watch the picker snap back to Investigate on an empty
        // round-trip. While the user has explicitly chosen a worktree
        // selection, keep it — just blank the branch name in the
        // `.newBranch` case so the field stays in "pending name" mode
        // rather than reverting intent.
        let trimmed = state.workspaceQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
          switch state.selectedWorkspace {
          case .newBranch:
            state.selectedWorkspace = .newBranch(name: "")
          case .existingBranch, .existingWorktree, .repoRoot:
            state.selectedWorkspace = .repoRoot
          }
        } else {
          // Typing a non-empty query re-infers the selection from the
          // current query + known worktrees/branches. Exact matches win;
          // otherwise we treat the query as a new branch name.
          state.selectedWorkspace = Self.inferSelection(
            from: state.workspaceQuery,
            state: state
          )
        }
        state.validationMessage = nil
        return .none

      case .binding(\.selectedRepositoryID):
        // Reload the branch list whenever the repo changes.
        state.validationMessage = nil
        state.selectedWorkspace = .repoRoot
        state.workspaceQuery = ""
        state.availableLocalBranches = []
        state.availableRemoteBranches = []
        state.availableRepositoryRemoteTargets = []
        state.destination = .local
        return .send(.task)

      case .binding(\.prompt):
        return handlePromptChange(state: &state)

      case .binding:
        state.validationMessage = nil
        return .none

      case .task:
        // Snapshot the remote catalog so the destination picker and the
        // (future) workspace autocomplete have data without forcing
        // `@Shared` onto State — keeps KeyPath Sendability for the
        // existing binding cases.
        @Shared(.remoteHosts) var remoteHosts: [RemoteHost]
        @Shared(.remoteWorkspaces) var remoteWorkspaces: [RemoteWorkspace]
        state.availableRemoteHosts = remoteHosts
        state.availableRemoteWorkspaces = remoteWorkspaces
        if let repoID = state.selectedRepositoryID,
          let repository = state.availableRepositories[id: repoID]
        {
          @Shared(.repositorySettings(repository.rootURL)) var repositorySettings
          state.availableRepositoryRemoteTargets = repositorySettings.remoteTargets
        } else {
          state.availableRepositoryRemoteTargets = []
        }
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
        // When a PR is resolved, the workspace was pinned to the PR's
        // head branch — never reinfer over that. Otherwise, re-run
        // inference since the query may have matched only after branches
        // loaded.
        if case .resolved = state.pullRequestLookup {
          return .none
        }
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
            // No session context: branch-name generation happens before
            // the session exists, so there's no transcript file to
            // append to. Skipped in v1.
            let raw = try await backgroundInferenceClient.infer(inferencePrompt, nil)
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

      case .destinationChanged(let destination):
        state.destination = destination
        if case .repositoryRemote(let targetID) = destination,
          let target = state.availableRepositoryRemoteTargets.first(where: { $0.id == targetID })
        {
          state.remoteWorkingDirectoryDraft = target.remoteWorkingDirectory
        }
        // Clear any stale local-flow validation message when the user
        // switches away; the remote flow validates on a different field.
        state.validationMessage = nil
        return .none

      case .agentSelected(let agent):
        state.agent = agent
        return .none

      case .saveDraftButtonTapped:
        // Drafts capture the local-flow shape only. Saving from a remote
        // destination would silently lose the host/path on resume; surface
        // that explicitly rather than persisting a half-truthful draft.
        if state.destination.isRemote {
          state.validationMessage = "Drafts only support local destinations for now."
          return .none
        }
        let draft = Draft(
          id: state.editingDraftID ?? UUID(),
          repositoryID: state.selectedRepositoryID,
          prompt: state.prompt,
          agent: state.agent,
          workspaceQuery: state.workspaceQuery,
          planMode: state.planMode,
          createdAt: Date(),
          updatedAt: Date()
        )
        state.validationMessage = nil
        return .send(.delegate(.draftSaved(draft)))

      case .createButtonTapped:
        if case .repositoryRemote(let targetID) = state.destination {
          guard let target = state.availableRepositoryRemoteTargets.first(where: { $0.id == targetID }) else {
            state.validationMessage = "Pick a remote target."
            return .none
          }
          return handleRemoteCreate(
            state: &state,
            hostID: target.hostID,
            remoteWorkingDirectory: target.remoteWorkingDirectory,
            repositoryIDOverride: state.selectedRepositoryID,
            repositoryRemoteTargetID: target.id
          )
        }
        if case .remote(let hostID) = state.destination {
          return handleRemoteCreate(
            state: &state,
            hostID: hostID,
            remoteWorkingDirectory: nil,
            repositoryIDOverride: nil,
            repositoryRemoteTargetID: nil
          )
        }
        return handleLocalCreate(state: &state)

      case .setValidationMessage(let message):
        state.validationMessage = message
        return .none

      case .setCreating(let creating):
        state.isCreating = creating
        return .none

      case .sessionReady(let session):
        state.isCreating = false
        // Emit `.bookmarkSaved` alongside `.created` when the user
        // opted into saving. Ordering matters — BoardFeature persists
        // the bookmark before (or independent of) spawning session
        // follow-up work, so the bookmark pill is already in state
        // when the new session card appears.
        var effects: [Effect<Action>] = []
        if let bookmark = state.pendingBookmarkToSave(for: session) {
          effects.append(.send(.delegate(.bookmarkSaved(bookmark))))
        }
        if let draftID = state.editingDraftID {
          effects.append(.send(.delegate(.draftConsumed(id: draftID))))
        }
        effects.append(.send(.delegate(.created(session))))
        return .merge(effects)

      case .creationFailed(let message):
        state.isCreating = false
        state.validationMessage = message
        return .none

      case .pullRequestLookupResolved(let context):
        return applyPullRequestResolution(state: &state, context: context)

      case .pullRequestLookupNotMatched(let parsed, let reason):
        // Only transition if the URL is still the one the sheet thinks
        // it's tracking — protects against stale effects racing past a
        // user who already cleared the URL.
        guard Self.shouldAcceptLookupOutcome(for: parsed, state: state) else {
          return .none
        }
        state.pullRequestLookup = .failed(parsed: parsed, message: reason)
        state.validationMessage = nil
        return .none

      case .pullRequestLookupFailed(let parsed, let message):
        guard Self.shouldAcceptLookupOutcome(for: parsed, state: state) else {
          return .none
        }
        state.pullRequestLookup = .failed(parsed: parsed, message: message)
        state.validationMessage = nil
        return .none

      case .pullRequestDismissTapped:
        let parsed: ParsedPullRequestURL
        switch state.pullRequestLookup {
        case .idle, .dismissed:
          return .none
        case .fetching(let p):
          parsed = p
        case .resolved(let context):
          parsed = context.parsed
        case .failed(let p, _):
          parsed = p
        }
        state.pullRequestLookup = .dismissed(parsed)
        state.validationMessage = nil
        return .cancel(id: CancelID.pullRequestLookup)

      case .delegate:
        return .none
      }
    }
  }

  // MARK: - Local create

  /// Git-backed spawn path: validates the repo+workspace selection, then
  /// (in an effect) creates or adopts a `Worktree`, spawns the terminal
  /// tab, and emits `.sessionReady` with an `AgentSession`.
  ///
  /// Sibling of `handleRemoteCreate` — keep their validation rules and
  /// agent-command composition in sync when touching either.
  private func handleLocalCreate(state: inout State) -> Effect<Action> {
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
    if state.saveAsBookmark {
      let trimmedName = state.bookmarkName.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmedName.isEmpty else {
        state.validationMessage = "Bookmark name required."
        return .none
      }
    }
    state.validationMessage = nil
    // Sheet dismisses immediately on Create (parent flips
    // `state.newTerminalSheet = nil` upon receiving `.spawnRequested`),
    // so we don't bother flipping `isCreating` — the spinner would
    // never be visible.

    // When the sheet was pre-configured from a pasted PR URL, we
    // already have a high-quality human title ready. Pass it through
    // so the card shows "PR #42: Fix the widget" from moment one,
    // instead of the URL hostname that the prompt slice would yield.
    let suggestedDisplayName: String? = {
      if case .resolved(let context) = state.pullRequestLookup {
        return "PR #\(context.parsed.number): \(context.metadata.title)"
      }
      return nil
    }()

    let agent = state.agent
    let planMode = agent?.supportsPlanMode == true && state.planMode
    // Mirror supacode's sidebar flow: obey the global "Fetch origin
    // before creating worktree" toggle so both paths behave the same.
    @Shared(.settingsFile) var settingsFile
    let fetchOriginBeforeCreation = settingsFile.global.fetchOriginBeforeWorktreeCreation
    let bypassPermissions =
      UserDefaults.standard.object(forKey: "supacool.bypassPermissions") as? Bool ?? true
    let sessionID = UUID()
    let rerunOwnedWorktreeID = state.rerunOwnedWorktreeID
    let removeBackingWorktreeOnDelete = Self.shouldRemoveBackingWorktreeOnDelete(
      selection: selection
    )
    let prLookupAtSubmit = state.pullRequestLookup

    let request = SessionSpawner.LocalRequest(
      sessionID: sessionID,
      repository: repository,
      selection: selection,
      agent: agent,
      prompt: trimmedPrompt,
      planMode: planMode,
      bypassPermissions: bypassPermissions,
      fetchOriginBeforeCreation: fetchOriginBeforeCreation,
      rerunOwnedWorktreeID: rerunOwnedWorktreeID,
      pullRequestLookup: prLookupAtSubmit,
      suggestedDisplayName: suggestedDisplayName,
      removeBackingWorktreeOnDelete: removeBackingWorktreeOnDelete
    )

    // Seed for the placeholder tray card the parent shows during the
    // worktree-creation window. The parent overwrites this with the
    // real session displayName once the spawn succeeds.
    let placeholderDisplayName =
      suggestedDisplayName
      ?? AgentSession.deriveDisplayName(from: trimmedPrompt, fallbackID: sessionID)

    let bookmarkToSave: Bookmark? = {
      guard state.saveAsBookmark else { return nil }
      let trimmedName = state.bookmarkName.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmedName.isEmpty else { return nil }
      let worktreeMode: Bookmark.WorktreeMode = {
        switch selection {
        case .repoRoot: return .repoRoot
        case .newBranch, .existingBranch, .existingWorktree: return .newWorktree
        }
      }()
      return Bookmark(
        id: state.editingBookmarkID ?? UUID(),
        repositoryID: repoID,
        name: trimmedName,
        prompt: trimmedPrompt,
        agent: agent,
        worktreeMode: worktreeMode,
        planMode: planMode
      )
    }()

    var effects: [Effect<Action>] = []
    if let bookmark = bookmarkToSave {
      effects.append(.send(.delegate(.bookmarkSaved(bookmark))))
    }
    if let draftID = state.editingDraftID {
      // Launching from a draft consumes it. Sent before `.spawnRequested`
      // so the parent removes the pill from the board before the new
      // session card appears, avoiding a flash of "draft + spawning
      // session" overlap.
      effects.append(.send(.delegate(.draftConsumed(id: draftID))))
    }
    effects.append(
      .send(.delegate(.spawnRequested(request, displayName: placeholderDisplayName)))
    )
    return .merge(effects)
  }

  // MARK: - Remote create

  /// Fork of `createButtonTapped` for remote sessions: no git, no
  /// worktree. Finds (or creates) a `RemoteWorkspace` for the entered
  /// path, builds a shim `Worktree` + `RemoteSpawnInvocation`, sends
  /// `.createRemoteTab`, and produces the `AgentSession` with the
  /// remote fields populated so the board classifier picks it up as
  /// `.disconnected` the moment the link drops.
  private func handleRemoteCreate(
    state: inout State,
    hostID: RemoteHost.ID,
    remoteWorkingDirectory: String?,
    repositoryIDOverride: Repository.ID?,
    repositoryRemoteTargetID: RepositoryRemoteTarget.ID?
  ) -> Effect<Action> {
    let trimmedPrompt = state.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedPath =
      (remoteWorkingDirectory ?? state.remoteWorkingDirectoryDraft)
      .trimmingCharacters(in: .whitespacesAndNewlines)

    @Shared(.remoteHosts) var remoteHosts: [RemoteHost]
    @Shared(.remoteWorkspaces) var remoteWorkspaces: [RemoteWorkspace]
    guard let host = remoteHosts.first(where: { $0.id == hostID }) else {
      state.validationMessage = "Pick a remote host."
      return .none
    }
    guard !trimmedPath.isEmpty else {
      state.validationMessage = "Remote working directory required."
      return .none
    }
    guard trimmedPath.hasPrefix("/") || trimmedPath.hasPrefix("~") else {
      state.validationMessage = "Remote path must be absolute (e.g. /home/me/code)."
      return .none
    }
    if state.agent != nil && trimmedPrompt.isEmpty {
      state.validationMessage = "Prompt required."
      return .none
    }
    guard let localSocketPath = terminalClient.hookSocketPath() else {
      state.validationMessage = "Agent hook socket isn't running — can't tunnel hooks."
      return .none
    }

    state.validationMessage = nil
    state.isCreating = true

    // Reuse an existing workspace record if one already points at this
    // path; otherwise persist a new one and reference it by id.
    let existing = remoteWorkspaces.first(where: {
      $0.hostID == hostID && $0.remoteWorkingDirectory == trimmedPath
    })
    let workspace: RemoteWorkspace = existing
      ?? RemoteWorkspace(hostID: hostID, remoteWorkingDirectory: trimmedPath)
    if existing == nil {
      $remoteWorkspaces.withLock { $0.append(workspace) }
    }

    let sessionID = UUID()
    let tmuxSessionName = "supacool-\(sessionID.uuidString.lowercased())"
    let worktreeKey = "remote:\(host.sshAlias):\(trimmedPath)"
    let repositoryID = repositoryIDOverride ?? worktreeKey
    let agent = state.agent
    let planMode = agent?.supportsPlanMode == true && state.planMode
    let bypassPermissions =
      UserDefaults.standard.object(forKey: "supacool.bypassPermissions") as? Bool ?? true

    let agentCommand: String?
    if let agent, !trimmedPrompt.isEmpty {
      agentCommand = agent.command(
        prompt: trimmedPrompt,
        bypassPermissions: bypassPermissions,
        planMode: planMode
      )
    } else if let agent {
      agentCommand = agent.commandWithoutPrompt(
        bypassPermissions: bypassPermissions,
        planMode: planMode
      )
    } else {
      agentCommand = nil
    }

    let invocation = RemoteSpawnInvocation(
      sshAlias: host.sshAlias,
      user: host.connection.user,
      hostname: host.connection.hostname,
      port: host.connection.port,
      identityFile: host.connection.identityFile,
      deferToSSHConfig: host.deferToSSHConfig,
      remoteWorkingDirectory: trimmedPath,
      remoteSocketPath: "\(host.overrides.effectiveRemoteTmpdir)"
        + "/supacool-hook-\(sessionID.uuidString.lowercased().prefix(12)).sock",
      localSocketPath: localSocketPath,
      tmuxSessionName: tmuxSessionName,
      worktreeID: worktreeKey,
      tabID: sessionID,
      surfaceID: sessionID,
      agentCommand: agentCommand,
      agent: agent
    )
    let sshCommand = remoteSpawnClient.sshInvocation(invocation)
    let worktreeShim = Worktree(
      id: worktreeKey,
      name: workspace.displayName,
      detail: "",
      workingDirectory: URL(fileURLWithPath: "/"),
      repositoryRootURL: URL(fileURLWithPath: "/")
    )

    let seededReferences = initialReferences(
      prompt: trimmedPrompt,
      pullRequestLookup: state.pullRequestLookup
    )

    let session = AgentSession(
      id: sessionID,
      repositoryID: repositoryID,
      worktreeID: worktreeKey,
      agent: agent,
      initialPrompt: trimmedPrompt,
      removeBackingWorktreeOnDelete: false,
      planMode: planMode,
      references: seededReferences,
      referencesScannedAt: seededReferences.isEmpty ? nil : Date(),
      remoteWorkspaceID: workspace.id,
      remoteHostID: hostID,
      repositoryRemoteTargetID: repositoryRemoteTargetID,
      tmuxSessionName: tmuxSessionName
    )

    let terminalClient = self.terminalClient
    return .run { send in
      await terminalClient.send(
        .createRemoteTab(worktreeShim, command: sshCommand, id: sessionID)
      )
      await send(.sessionReady(session))
    }
  }

  private func initialReferences(
    prompt: String,
    pullRequestLookup: PullRequestLookupState
  ) -> [SessionReference] {
    var refs = scannerClient.scanText(prompt)
    if case .resolved(let context) = pullRequestLookup {
      refs.append(
        .pullRequest(
          owner: context.parsed.owner,
          repo: context.parsed.repo,
          number: context.parsed.number,
          state: nil
        )
      )
    }
    return Self.dedupeReferences(refs)
  }

  private nonisolated static func dedupeReferences(_ refs: [SessionReference]) -> [SessionReference] {
    var seen = Set<String>()
    var result: [SessionReference] = []
    for ref in refs where seen.insert(ref.dedupeKey).inserted {
      result.append(ref)
    }
    return result
  }

  // MARK: - PR URL handling

  /// Kick off (or cancel) a gh-backed PR lookup based on the current
  /// prompt content. Returns the effect that performs the lookup —
  /// mutating the sheet state inline on transitions keeps the side-effect
  /// flow readable.
  private func handlePromptChange(
    state: inout State
  ) -> Effect<Action> {
    state.validationMessage = nil
    let parsed = ParsedPullRequestURL.firstMatch(in: state.prompt)

    switch (parsed, state.pullRequestLookup) {
    case (nil, .idle):
      return .none
    case (nil, _):
      // URL was removed — reset PR state but leave the workspace/repo
      // the user's already configured. They may still want to submit.
      state.pullRequestLookup = .idle
      return .cancel(id: CancelID.pullRequestLookup)
    case (let parsed?, .fetching(let pending)) where pending == parsed:
      return .none
    case (let parsed?, .resolved(let context)) where context.parsed == parsed:
      return .none
    case (let parsed?, .failed(let failed, _)) where failed == parsed:
      // Same URL already failed once — don't thrash the API.
      return .none
    case (let parsed?, .dismissed(let dismissed)) where dismissed == parsed:
      // User dismissed this exact URL — stay dismissed until they edit
      // it to something different.
      return .none
    case (let parsed?, _):
      return startPullRequestLookup(state: &state, parsed: parsed)
    }
  }

  private func startPullRequestLookup(
    state: inout State,
    parsed: ParsedPullRequestURL
  ) -> Effect<Action> {
    state.pullRequestLookup = .fetching(parsed)
    // Extract (id, rootURL) pairs synchronously while we're still on the
    // main actor. Repository's Identifiable conformance is main-actor
    // isolated; touching .id inside a nonisolated Task is a Swift 6 error.
    let repoCoordinates: [(String, URL)] = state.availableRepositories.map {
      ($0.id, $0.rootURL)
    }
    return .run { [gitClient, supacoolGithubPR] send in
      // Race the gh call and the repo-matching lookup in parallel — the
      // gh call is the slow one, repo matching is just a few git plumbing
      // invocations. This keeps time-to-banner tight.
      async let metadataTask = supacoolGithubPR.fetchMetadata(
        parsed.owner,
        parsed.repo,
        parsed.number
      )
      async let repoMatchTask = findMatchingRepositoryID(
        candidates: repoCoordinates,
        owner: parsed.owner,
        repo: parsed.repo,
        gitClient: gitClient
      )

      do {
        let metadata = try await metadataTask
        let matchedID = await repoMatchTask

        if metadata.headRepositoryOwner != parsed.owner {
          await send(
            .pullRequestLookupNotMatched(
              parsed: parsed,
              reason:
                "Fork PRs aren't auto-checked-out yet. "
                + "Run `gh pr checkout \(parsed.number)` in a normal terminal instead."
            )
          )
          return
        }
        guard let matchedID else {
          await send(
            .pullRequestLookupNotMatched(
              parsed: parsed,
              reason:
                "No configured repo matches \(parsed.owner)/\(parsed.repo). "
                + "Add it in Settings → Repositories first."
            )
          )
          return
        }

        let context = PullRequestContext(
          parsed: parsed,
          metadata: metadata,
          matchedRepositoryID: matchedID,
          isFork: false
        )
        await send(.pullRequestLookupResolved(context))
      } catch {
        newTerminalLogger.warning(
          "PR lookup failed for \(parsed.url): \(error.localizedDescription)"
        )
        // Surface the actual failure reason — the original generic
        // "is gh installed?" message masked plenty of unrelated causes
        // (JSON parse errors, network issues, auth scope mismatches).
        // Truncate to keep the banner readable; full text goes to the log.
        let raw = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = String(raw.prefix(160))
        await send(
          .pullRequestLookupFailed(
            parsed: parsed,
            message: "Couldn't fetch PR details: \(detail)"
          )
        )
      }
    }
    .cancellable(id: CancelID.pullRequestLookup, cancelInFlight: true)
  }

  /// Apply a resolved PR context to the sheet: pin the repo, pre-fill the
  /// workspace field with the PR's head branch, and queue a branch
  /// reload if the repo actually changed.
  private func applyPullRequestResolution(
    state: inout State,
    context: PullRequestContext
  ) -> Effect<Action> {
    guard Self.shouldAcceptLookupOutcome(for: context.parsed, state: state) else {
      return .none
    }

    state.pullRequestLookup = .resolved(context)
    state.validationMessage = nil

    let repoChanged = state.selectedRepositoryID != context.matchedRepositoryID
    if repoChanged {
      state.selectedRepositoryID = context.matchedRepositoryID
      state.availableLocalBranches = []
      state.availableRemoteBranches = []
    }
    state.workspaceQuery = context.metadata.headRefName
    state.selectedWorkspace = .existingBranch(name: context.metadata.headRefName)

    return repoChanged ? .send(.task) : .none
  }

  /// Guard: reject lookup outcomes for a URL that's no longer the one
  /// the sheet is tracking (the user edited or removed it mid-flight).
  static func shouldAcceptLookupOutcome(
    for parsed: ParsedPullRequestURL,
    state: State
  ) -> Bool {
    switch state.pullRequestLookup {
    case .fetching(let pending): return pending == parsed
    case .idle, .resolved, .failed, .dismissed: return false
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

  /// If the target worktree directory is still on disk and looks like a
  /// live git worktree (its `.git` marker is present), return a Worktree
  /// pointing at it so the caller can skip `git worktree add`. Used to
  /// recover from rerun where the previous session's directory was
  /// preserved but git's record (or the in-app cache) drifted. Returns
  /// nil when there's nothing to adopt — let the normal create path
  /// handle (and surface) the real failure.
  /// Returns true when the `.existingBranch(name: branchName)` selection
  /// in `createButtonTapped` was pre-armed by the PR banner (as opposed
  /// to typed manually in the workspace field). Drives the force-fetch
  /// path: PR branches are remote-by-definition, so we fetch even when
  /// the global `fetchOriginBeforeWorktreeCreation` setting is off.
  nonisolated static func isPRArmedExistingBranch(
    pullRequestLookup: PullRequestLookupState,
    branchName: String
  ) -> Bool {
    guard case .resolved(let context) = pullRequestLookup else { return false }
    return context.metadata.headRefName == branchName
  }

  nonisolated static func adoptExistingWorktreeDirectory(
    branchName: String,
    baseDirectory: URL,
    repoRootURL: URL
  ) -> Worktree? {
    let worktreeURL = baseDirectory
      .appending(path: branchName, directoryHint: .isDirectory)
      .standardizedFileURL
    let fileManager = FileManager.default
    let worktreePath = worktreeURL.path(percentEncoded: false)
    let gitMarkerPath = worktreeURL.appendingPathComponent(".git").path(percentEncoded: false)
    guard fileManager.fileExists(atPath: worktreePath),
      fileManager.fileExists(atPath: gitMarkerPath)
    else {
      return nil
    }
    let repositoryRootURL = repoRootURL.standardizedFileURL
    return Worktree(
      id: worktreePath,
      name: branchName,
      detail: "",
      workingDirectory: worktreeURL,
      repositoryRootURL: repositoryRootURL,
      createdAt: nil,
      branch: branchName
    )
  }

  /// Policy: any session that points at a worktree (= anything except
  /// `.repoRoot`) cleans up that worktree when the card is removed.
  /// The earlier "only own what we created" carve-out gave us
  /// orphaned directories whenever a user picked an existing worktree
  /// from the picker — too easy to forget the cleanup. The
  /// `sessionsUsingWorkspace` ref-count guard in `BoardFeature
  /// .removeSession` still prevents removal of a worktree that
  /// another card is using.
  static func shouldRemoveBackingWorktreeOnDelete(
    selection: WorkspaceSelection
  ) -> Bool {
    switch selection {
    case .repoRoot:
      return false
    case .existingWorktree, .existingBranch, .newBranch:
      return true
    }
  }
}

/// Error surfaced from the create effect when the state snapshot taken at
/// submit-time no longer matches reality (e.g. the picked existing
/// worktree was removed between picker-time and submit).
nonisolated enum NewTerminalError: LocalizedError {
  case worktreeMissing
  /// Neither the local branch nor the remote-tracking ref exists, and a
  /// refspec fetch against the first configured remote failed. Without
  /// a resolvable ref, `git worktree add` would emit its cryptic
  /// "invalid reference" — this surfaces something the user can act on.
  case branchNotFoundAfterFetch(name: String)
  /// `git worktree add <path> <branch>` would fail because the branch is
  /// already checked out at a *different* path. Carries the conflicting
  /// `Worktree` so the BoardFeature can offer Reuse / Delete & recreate.
  case branchAlreadyCheckedOut(branch: String, existing: Worktree)

  var errorDescription: String? {
    switch self {
    case .worktreeMissing: "Picked worktree is no longer available."
    case .branchNotFoundAfterFetch(let name):
      "Branch '\(name)' not found locally or on any configured remote."
    case .branchAlreadyCheckedOut(let branch, let existing):
      "Branch '\(branch)' is already checked out at "
        + "\(existing.workingDirectory.path(percentEncoded: false))."
    }
  }
}

extension String {
  /// Returns the remote name if this ref starts with `<remote>/`, matched
  /// against known remotes. Longest-match wins to handle ambiguous
  /// prefixes (e.g. `origin` vs `origin-mirror`). Named distinctly from
  /// upstream supacode's `matchingRemote` to avoid collisions on future
  /// upstream syncs.
  nonisolated func supacoolMatchingRemote(from remotes: [String]) -> String? {
    remotes.sorted { $0.count > $1.count }.first { hasPrefix("\($0)/") }
  }
}

/// Find the first configured repository whose GitHub remote matches the
/// given owner/repo pair. Runs the `remoteInfo` probes in parallel so the
/// PR banner appears quickly even when the user has many repos
/// configured. Case-insensitive match — GitHub coerces casing anyway.
///
/// Takes plain tuples instead of `IdentifiedArrayOf<Repository>` because
/// Repository's Identifiable conformance is `@MainActor`-isolated and we
/// run inside a nonisolated Task here.
nonisolated func findMatchingRepositoryID(
  candidates: [(String, URL)],
  owner: String,
  repo: String,
  gitClient: GitClientDependency
) async -> String? {
  await withTaskGroup(of: (String, GithubRemoteInfo?).self) { group in
    for (id, rootURL) in candidates {
      group.addTask {
        (id, await gitClient.remoteInfo(rootURL))
      }
    }
    for await (id, info) in group {
      guard let info else { continue }
      if info.owner.caseInsensitiveCompare(owner) == .orderedSame
        && info.repo.caseInsensitiveCompare(repo) == .orderedSame
      {
        group.cancelAll()
        return id
      }
    }
    return nil
  }
}
