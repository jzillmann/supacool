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
    /// Live-updated by BoardFeature when the underlying repository list
    /// changes — keeps the open sheet's repository picker in sync with
    /// repos added (or removed) while the user is mid-prompt.
    var availableRepositories: IdentifiedArrayOf<Repository>
    var selectedRepositoryID: Repository.ID?
    var prompt: String = ""
    /// `nil` = raw shell session (no agent CLI invoked).
    var agent: AgentType? = .claude
    /// Model passed to the agent's model flag at launch. Empty string =
    /// "Default" (no flag rendered — the agent picks its own model).
    /// Resets when the agent changes since model ids are per-agent.
    var model: String = ""

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
    ///
    /// Defaults to a blank worktree (`.newBranch(name: "")`) — agents
    /// must never accidentally inherit the main checkout. Spawning into
    /// `.repoRoot` has caused the main repo to drift onto unrelated
    /// branches and accumulate uncommitted changes when an agent runs
    /// `git checkout` / `gh pr checkout` / `git merge` inside it. Users
    /// who genuinely want Main scope opt in via the segmented picker.
    var selectedWorkspace: WorkspaceSelection = .newBranch(name: "")
    /// The free-text query the user types into the workspace field.
    /// Empty = no branch name yet — the segmented picker decides whether
    /// that resolves to a blank worktree (default) or the main checkout.
    var workspaceQuery: String = ""
    /// Shadow of the last `workspaceQuery` value we've already accounted
    /// for, used to tell a genuine user edit apart from SwiftUI's
    /// same-value binding re-emissions (focus changes / `@Bindable`
    /// round-trips). Without this, a spurious round-trip with the field
    /// still empty would flip `workspaceQueryUserEdited` mid-flight and
    /// block Linear branch auto-fill. Kept in sync everywhere we write
    /// `workspaceQuery` programmatically so those writes never look like
    /// user edits on the round-trip that follows.
    var previousWorkspaceQuery: String = ""
    /// Loaded lazily on `.task`. Local branch names (e.g. `["main", "feat-x"]`).
    var availableLocalBranches: [String] = []
    /// Loaded lazily on `.task`. Remote tracking refs (e.g. `["origin/main", "origin/feat-x"]`).
    var availableRemoteBranches: [String] = []
    var isLoadingBranches: Bool = false

    // MARK: - Misc

    var validationMessage: String?
    var isCreating: Bool = false
    var planMode: Bool = false
    /// True when the user armed Claude Code's Remote Control on launch.
    /// Only meaningful for agents that support it; gated at submit time
    /// against `agent.supportsRemoteControl`.
    var remoteControl: Bool = false
    /// Optional session title passed to `--remote-control "<name>"`. Blank
    /// → Claude auto-names the remote session. Sheet-local only — not
    /// persisted on bookmarks/drafts.
    var remoteControlName: String = ""
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

    // MARK: - Linear ticket lookup

    /// In-flight fetch identifier (the ticket id being fetched) so the
    /// reducer can ignore stale completions when the user has already
    /// edited past them. `nil` while no fetch is running.
    var pendingLinearTicketID: String?
    /// Cache of resolved Linear ticket titles keyed by uppercase id
    /// (`CEN-6690`). Persists for the life of the sheet so re-typing the
    /// same id doesn't re-hit the API. Negative results are stored as
    /// empty-string sentinels so we don't loop on missing tickets.
    var linearTitleCache: [String: String] = [:]
    /// Ids whose lookup failed for a *transient* reason (network blip,
    /// cancellation, or no API key yet) as opposed to a genuine "no such
    /// ticket". They're cached as empty sentinels too — so continued
    /// typing doesn't thrash the API — but they're evicted the moment the
    /// ticket id leaves the prompt, so removing + re-pasting the id (or
    /// closing/reopening the sheet) retries instead of being stuck on the
    /// first bad attempt. This is the "close, reopen, re-paste fixes it"
    /// bug: a single early hiccup used to poison the id for the whole
    /// sheet.
    var linearTransientFailureIDs: Set<String> = []
    /// Cache of Linear's own suggested branch name, owner-prefix stripped
    /// (`cen-6690-streamline-the-foobar`), keyed by uppercase id. Empty
    /// string = Linear returned no branch name, so the workspace branch
    /// falls back to the title-derived slug. Kept in lockstep with
    /// `linearTitleCache` — same lifecycle, same transient eviction.
    var linearBranchNameCache: [String: String] = [:]
    /// User-facing note about the current prompt ticket's lookup — a
    /// failure reason ("No Linear API key…") or "not found". Nil when the
    /// lookup is healthy (scanning or resolved). Surfaced by the sheet's
    /// Linear status chip.
    var linearLookupMessage: String?
    /// True the first time the user has manually edited the workspace
    /// query field. Used to decide whether to overwrite the field with
    /// a freshly-fetched ticket-derived branch name (we won't, once the
    /// user has signalled intent).
    var workspaceQueryUserEdited: Bool = false

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
      remoteControl = previous.remoteControl
      model = previous.model ?? ""

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
        // A rerun's pre-filled branch is deliberate content; mark it edited
        // so a Linear ticket in the carried-over prompt can't auto-fill over
        // it, and mirror the shadow so the first round-trip is a no-op.
        previousWorkspaceQuery = workspaceQuery
        workspaceQueryUserEdited = !workspaceQuery.isEmpty
      } else {
        // The previous session ran at repo root. Rerun must preserve
        // that scope explicitly — the sheet's default flipped to a
        // blank worktree, so leaving this implicit would silently
        // convert a repo-root rerun into a worktree spawn.
        selectedWorkspace = .repoRoot
      }
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
      remoteControl = previous.remoteControl
      model = previous.model ?? ""
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
      remoteControl = bookmark.remoteControl
      model = bookmark.model ?? ""
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
      remoteControl = draft.remoteControl
      model = draft.model ?? ""
      workspaceQuery = draft.workspaceQuery
      previousWorkspaceQuery = draft.workspaceQuery
      // Initial best-effort selection inference. The branches list is
      // empty at init time so anything non-empty falls into `.newBranch`,
      // but `branchesLoaded` re-runs inference once the actual branches
      // arrive — at which point an existing-branch / existing-worktree
      // match takes over.
      let trimmed = workspaceQuery.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty {
        selectedWorkspace = .newBranch(name: trimmed)
        // A draft's saved branch is deliberate; protect it from auto-fill.
        workspaceQueryUserEdited = true
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
        planMode: session.planMode,
        remoteControl: session.remoteControl,
        model: session.model
      )
    }

    /// The model to launch with: trimmed, empty → nil ("Default"), and
    /// dropped entirely for agents without a model flag.
    var normalizedModel: String? {
      guard agent?.supportsModelSelection == true else { return nil }
      let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
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

    /// Background fetch of a Linear issue's naming (title + suggested
    /// branch) resolved successfully. `id` is the ticket id we asked about
    /// (uppercase, e.g. `CEN-6690`). When `naming` is nil we record a
    /// negative cache so the same id doesn't get re-fetched on every
    /// keystroke.
    case linearTicketTitleResolved(id: String, naming: LinearIssueNaming?)
    /// Background Linear fetch failed (network / auth / no key / etc).
    /// Caches an empty sentinel so the failure doesn't thrash the API on
    /// every keystroke, but marks the id transient so removing + re-pasting
    /// it retries. `message` is a short user-facing reason shown in the
    /// Linear status chip.
    case linearTicketTitleFailed(id: String, message: String?)
    /// User tapped Retry on the Linear failure chip. Drops the cached
    /// failure for the current prompt ticket and re-runs the lookup
    /// immediately (no debounce).
    case linearLookupRetryTapped

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
      /// card while the worktree is being created. `draftSnapshot` is
      /// a `Draft`-shaped capture of the user's submitted values; if
      /// the spawn fails, BoardFeature attaches it to the failure tray
      /// card so tap-to-reopen can resurrect the sheet with the same
      /// values pre-filled.
      case spawnRequested(
        SessionSpawner.LocalRequest,
        displayName: String,
        draftSnapshot: Draft
      )
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
  @Dependency(LinearClient.self) var linearClient
  @Dependency(\.continuousClock) var clock

  nonisolated enum CancelID: Hashable, Sendable {
    case branchNameSuggestion
    case loadBranches
    case pullRequestLookup
    case linearTicketLookup
  }

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding(\.workspaceQuery):
        // BindingReducer has already written the new text. SwiftUI re-emits
        // this binding on focus changes / `@Bindable` round-trips with the
        // SAME value — those are not user edits. Only a genuine value change
        // flags the field as user-edited; otherwise an incidental round-trip
        // while the field is still empty would flip the flag mid-flight and
        // block Linear branch auto-fill (the "sometimes the branch doesn't
        // fill" race). Linear-title auto-fill only happens before this flips —
        // once the user actually touches the field we never overwrite.
        if state.workspaceQuery != state.previousWorkspaceQuery {
          state.workspaceQueryUserEdited = true
        }
        // Git refuses branch names containing whitespace. Replace any
        // typed (or pasted) whitespace with hyphens inline so the user
        // never has to see the "can't contain spaces" error — what they
        // see in the field is what will actually be used.
        if state.workspaceQuery.contains(where: \.isWhitespace) {
          state.workspaceQuery = state.workspaceQuery.replacing(/\s+/, with: "-")
        }
        // An empty query used to flip the selection back to `.repoRoot`,
        // which fought the new explicit Main/Worktree segmented picker:
        // the user would click Worktree, focus the Workspace field (which
        // re-emits the binding via @Bindable's round-trip), and watch the
        // picker snap back to Main on an empty round-trip. While the user
        // has explicitly chosen a worktree
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
        state.previousWorkspaceQuery = state.workspaceQuery
        state.validationMessage = nil
        return .none

      case .binding(\.selectedRepositoryID):
        // Reload the branch list whenever the repo changes. Reset back
        // to the sheet's default — a blank worktree — so the picker
        // doesn't carry a stale branch name across repos.
        state.validationMessage = nil
        state.selectedWorkspace = .newBranch(name: "")
        state.workspaceQuery = ""
        state.previousWorkspaceQuery = ""
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
        state.previousWorkspaceQuery = state.workspaceQuery
        // Picking a concrete existing branch/worktree from autocomplete is a
        // deliberate branch-name choice Linear auto-fill must not clobber.
        // Toggling the Main/Worktree segment yields an empty query and is
        // NOT — leave the flag alone so "click Worktree, then paste a ticket"
        // still auto-fills.
        if !state.workspaceQuery.isEmpty {
          state.workspaceQueryUserEdited = true
        }
        state.validationMessage = nil
        return .none

      case .cancelButtonTapped:
        return .send(.delegate(.cancel))

      case .suggestBranchNameTapped:
        guard !state.isSuggestingBranchName else { return .none }
        let prompt = state.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return .none }

        // Fast path: when the prompt names a Linear ticket and we already
        // have its title cached, derive the branch name from the title
        // directly. The LLM round-trip would just paraphrase the title
        // anyway, badly.
        if let ticketID = firstLinearTicketID(in: prompt)?.uppercased(),
          let title = state.linearTitleCache[ticketID], !title.isEmpty
        {
          let derived = branchNameFromLinear(
            ticketID: ticketID,
            title: title,
            linearBranchName: state.linearBranchNameCache[ticketID]
          )
          if !derived.isEmpty {
            return .send(.branchNameSuggested(derived))
          }
        }

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
        state.previousWorkspaceQuery = name
        state.selectedWorkspace = Self.inferSelection(from: name, state: state)
        // The wand button is the user explicitly accepting the suggestion;
        // their next manual edit should still flip the user-edited flag,
        // but a fresh suggestion shouldn't be blocked just because we
        // wrote into the field once via auto-fill earlier.
        state.workspaceQueryUserEdited = true
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
          remoteControl: state.remoteControl,
          model: state.normalizedModel,
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

      case .linearTicketTitleResolved(let id, let naming):
        // Stale guard: only accept the result if it matches the id we
        // most recently kicked off. Anything older is yesterday's news.
        guard state.pendingLinearTicketID == id else { return .none }
        state.pendingLinearTicketID = nil
        // A real answer arrived — this id is no longer a transient failure.
        state.linearTransientFailureIDs.remove(id)
        let cleaned = naming?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Negative cache: empty string sentinel keeps us from re-fetching
        // a typo'd id on every keystroke. An empty title here is a genuine
        // "issue not found" (the API resolved but had no such issue), so —
        // unlike a transient failure — it stays cached across re-pastes.
        state.linearTitleCache[id] = cleaned
        // Cache Linear's own branch name with the owner prefix stripped
        // (`johannes/cen-6690-…` → `cen-6690-…`). Empty when Linear didn't
        // supply one, so the branch falls back to the title-derived slug.
        state.linearBranchNameCache[id] =
          naming?.branchName.map { linearBranchNameStrippingOwner($0, ticketID: id) } ?? ""
        state.linearLookupMessage = cleaned.isEmpty ? "Linear issue \(id) not found." : nil
        return Self.maybeAutoFillWorkspaceQueryFromLinear(state: &state)

      case .linearTicketTitleFailed(let id, let message):
        guard state.pendingLinearTicketID == id else { return .none }
        state.pendingLinearTicketID = nil
        // Cache an empty sentinel so a transient outage doesn't pummel the
        // API every time the user adds a character while the id sits in the
        // prompt. Mark it transient so removing + re-pasting the id retries
        // (see `linearTransientFailureIDs`). The user can also hit the wand
        // button to retry.
        state.linearTitleCache[id] = ""
        state.linearTransientFailureIDs.insert(id)
        state.linearLookupMessage = message
        return .none

      case .linearLookupRetryTapped:
        guard let ticketID = firstLinearTicketID(in: state.prompt)?.uppercased() else {
          return .none
        }
        // Clear the cached failure so the lookup actually re-runs (a
        // cached empty sentinel would otherwise short-circuit), then fire
        // immediately.
        state.linearTitleCache[ticketID] = nil
        state.linearBranchNameCache[ticketID] = nil
        state.linearTransientFailureIDs.remove(ticketID)
        return startLinearLookup(state: &state, ticketID: ticketID, debounce: false)

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
    .onChange(of: \.agent) { _, _ in
      Reduce { state, _ in
        // Model ids are per-agent vocabulary ("opus" means nothing to
        // codex) — flip back to Default whenever the agent changes.
        // `.onChange` only fires on actual value changes, so binding
        // round-trips can't wipe a prefilled model.
        state.model = ""
        return .none
      }
    }
  }

  // MARK: - Local create — handler lives in NewTerminalFeature+Create.swift

  // MARK: - Remote create — handlers live in NewTerminalFeature+Create.swift

  // MARK: - PR URL handling — handlers live in NewTerminalFeature+Lookups.swift

  // MARK: - Selection inference — helpers live in NewTerminalFeature+WorkspaceSelection.swift
}

// MARK: - NewTerminalError + String.supacoolMatchingRemote — live in NewTerminalFeature+WorkspaceSelection.swift

// MARK: - Linear-derived naming — helpers live in NewTerminalFeature+Lookups.swift
