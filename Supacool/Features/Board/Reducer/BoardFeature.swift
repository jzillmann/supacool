import ComposableArchitecture
import Foundation
import IdentifiedCollections

private nonisolated let boardLogger = SupaLogger("Board")

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
    @Shared(.remoteHosts) var remoteHosts: [RemoteHost] = []
    @Shared(.remoteWorkspaces) var remoteWorkspaces: [RemoteWorkspace] = []

    /// When non-nil, the root view shows this session's terminal full-screen
    /// instead of the board. Not persisted — fresh launches always land on
    /// the board.
    var focusedSessionID: AgentSession.ID?

    /// The new-terminal sheet state, if open.
    @Presents var newTerminalSheet: NewTerminalFeature.State?

    /// "Manage Worktrees…" inspector sheet state. Presented from the
    /// repo picker; lets the user see every worktree on disk for a
    /// given repo with classification + size + git metadata. Read-only
    /// in PR2 — multi-select + delete lands in PR3.
    @Presents var worktreeJanitor: WorktreeJanitorFeature.State?

    /// Sessions whose Auto-Observer is currently reading/deciding.
    /// Guards against re-entrant triggers on the same session.
    var autoObserverInFlight: Set<AgentSession.ID> = []

    /// The session a Rerun is replacing — kept around until the new
    /// session is successfully created so that a failed/cancelled
    /// rerun doesn't lose the original card. Cleared on successful
    /// create (the original is removed at that point) or on sheet
    /// cancel (the original stays put).
    var pendingRerunSessionID: AgentSession.ID?

    /// Populated when a user-triggered worktree prune completes (success
    /// or failure). The root view presents a summary alert off this state
    /// so the user sees concrete feedback — how many refs were cleaned,
    /// whether any session cards are now orphaned.
    var pruneAlert: PruneAlertState?

    /// Presented when a priority session's live terminal disappears
    /// during this app run. Lets the user jump straight into the now-
    /// detached card and decide whether to resume, rerun, or remove it.
    var priorityTerminationAlert: PriorityTerminationAlertState?

    /// Transient cards floating in the bottom-right tray over the board.
    /// Not persisted — refilled on each app launch by whichever subsystem
    /// owns the signal (stale hooks check, New Terminal drafts, etc.).
    var trayCards: IdentifiedArrayOf<TrayCard> = []
  }

  /// One-shot summary shown after a prune attempt. Identifiable so we
  /// can drive SwiftUI's `.alert(item:)` off it.
  nonisolated struct PruneAlertState: Equatable, Identifiable, Sendable {
    let id: UUID
    let repositoryID: Repository.ID
    let repositoryName: String
    /// Result of `git worktree prune --verbose`: either a count of
    /// pruned refs (success) or an error message surfaced to the user.
    let outcome: Outcome

    enum Outcome: Equatable, Sendable {
      case success(prunedCount: Int, orphanSessionIDs: [AgentSession.ID])
      case failure(message: String)
    }
  }

  nonisolated struct PriorityTerminationAlertState: Equatable, Identifiable, Sendable {
    let id: UUID
    let sessionID: AgentSession.ID
    let displayName: String
    let status: BoardSessionStatus

    init(
      id: UUID = UUID(),
      sessionID: AgentSession.ID,
      displayName: String,
      status: BoardSessionStatus
    ) {
      self.id = id
      self.sessionID = sessionID
      self.displayName = displayName
      self.status = status
    }

    var title: String { "Priority session terminated" }

    var message: String {
      switch status {
      case .interrupted:
        "\(displayName) stopped while the agent was still working."
      case .detached:
        "\(displayName) finished and its terminal exited."
      default:
        "\(displayName) terminated."
      }
    }
  }

  enum Action: BindableAction, Equatable {
    case binding(BindingAction<State>)

    // MARK: Session CRUD
    case createSession(AgentSession)
    case renameSession(id: AgentSession.ID, newName: String)
    case removeSession(id: AgentSession.ID)
    case togglePriority(id: AgentSession.ID)
    case markSessionActivity(id: AgentSession.ID)
    case markSessionCompletedOnce(id: AgentSession.ID)
    case updateSessionBusyState(id: AgentSession.ID, busy: Bool)
    case prioritySessionTerminated(id: AgentSession.ID, status: BoardSessionStatus)
    case dismissPriorityTerminationAlert
    /// Park: destroy the PTY to free resources, flag the session as
    /// parked so the board sorts it into the bottom bucket. Metadata
    /// (prompt, captured resume id) is preserved so the user can unpark
    /// via the existing Resume / Rerun paths.
    case parkSession(id: AgentSession.ID, repositories: [Repository])

    // MARK: Focus
    case focusSession(id: AgentSession.ID?)

    // MARK: Repo filter
    case toggleRepository(id: String)
    case showAllRepositories

    // MARK: New-terminal sheet
    case openNewTerminalSheet(repositories: [Repository])
    /// Opens the new-terminal sheet with workspace / repo fields pre-filled
    /// from a focused session's current context. Intended for the ⌘N /
    /// "new terminal" affordance inside FullScreenTerminalView — so a
    /// second terminal opened from a session that has converted to a
    /// worktree lands in the same worktree, not back at the default.
    case openNewTerminalSheetInheritingFrom(
      id: AgentSession.ID,
      repositories: [Repository]
    )
    case rerunDetachedSession(id: AgentSession.ID, repositories: [Repository])
    case resumeDetachedSession(id: AgentSession.ID, repositories: [Repository])
    /// Fallback resume path: no captured id, so we launch the agent's own
    /// built-in resume picker scoped to the session's working directory.
    case resumeDetachedSessionWithPicker(id: AgentSession.ID, repositories: [Repository])
    case resumeFailed(id: AgentSession.ID, message: String)
    /// User confirmed the "convert to worktree" popover on the repo-root
    /// pill in the focused terminal header. Creates the worktree on disk
    /// via git-wt and types `cd '<path>'` into the session's focused
    /// surface — no surface/process churn. The terminal stays alive in
    /// its current tab; the user reviews the command and presses Enter.
    case convertSessionToWorktree(
      id: AgentSession.ID,
      branchName: String,
      repositories: [Repository]
    )
    /// Internal success callback for `convertSessionToWorktree`. Fires on
    /// the main actor once `gitClient.createWorktree` returns, so we can
    /// update `currentWorkspacePath` synchronously with state. Kept
    /// separate from the `cd` send — the effect is interested in sending
    /// the text AND announcing the path change, but only the latter
    /// touches state.
    case _convertSessionToWorktreeSucceeded(id: AgentSession.ID, newWorkspacePath: String)
    case _convertSessionToWorktreeFailed(id: AgentSession.ID, message: String)
    case newTerminalSheet(PresentationAction<NewTerminalFeature.Action>)

    // MARK: Remote reconnect
    /// User clicked Reconnect on a `.disconnected` remote session card.
    /// Re-spawns ssh; `tmux new-session -A` re-attaches the surviving
    /// remote session.
    case reconnectRemoteSession(id: AgentSession.ID)
    case _reconnectFailed(id: AgentSession.ID, message: String)

    // MARK: Auto-Observer
    case toggleAutoObserver(id: AgentSession.ID)
    case setAutoObserverPrompt(id: AgentSession.ID, prompt: String)
    /// Fired by the view when a session transitions to idle or awaiting-input
    /// and has `autoObserver == true`. Starts a read → decide → respond effect.
    case autoObserverTriggered(id: AgentSession.ID)
    case _autoObserverDecided(id: AgentSession.ID, response: String?)

    // MARK: References (ticket ids, PR URLs)
    /// Fired from `SessionCardView.task` on first appearance. Triggers a
    /// scan of the Claude Code JSONL if the session's references are
    /// stale (never scanned, or `lastActivityAt > referencesScannedAt`).
    case cardAppeared(id: AgentSession.ID)
    case _referencesScanned(id: AgentSession.ID, refs: [SessionReference])
    /// Fetches fresh `PRState` for a pull-request reference via `gh pr view`
    /// and patches the in-place reference. Called after `_referencesScanned`
    /// for each unique PR, throttled by the cache window.
    case _refreshPRStatus(id: AgentSession.ID, ref: SessionReference)
    case _prStatusUpdated(id: AgentSession.ID, ref: SessionReference, state: PRState)

    // MARK: Auto display name
    /// Fired when the background inference client returns a suggested
    /// display name for a freshly created session. Applied only if the
    /// current name is still the deterministic slice (i.e. the user
    /// hasn't renamed in the meantime).
    case _autoDisplayNameSuggested(id: AgentSession.ID, suggested: String)

    // MARK: Tray
    /// Push a new tray card. De-dupes by `kind` so repeated launches don't
    /// stack multiple identical cards (e.g. two stale-hooks entries).
    case trayCardPushed(TrayCard)
    /// User tapped the card body. Behavior depends on `kind`.
    case trayCardPrimaryTapped(id: TrayCard.ID)
    /// User tapped the × on a card. Removes it for the session.
    case trayCardDismissed(id: TrayCard.ID)

    // MARK: Worktree prune
    /// User clicked the broom button next to a repo in the picker.
    /// Kicks off `git worktree prune --verbose` and surfaces a summary.
    case pruneWorktreesRequested(repositoryID: Repository.ID, repositoryName: String)
    /// Result from the prune effect — populates the summary alert.
    case _pruneWorktreesResult(PruneAlertState)
    /// User hit "Remove orphans" in the summary alert.
    case confirmPruneOrphans(sessionIDs: [AgentSession.ID])
    /// Alert was dismissed (OK / Keep / swipe-away).
    case dismissPruneAlert

    // MARK: Worktree janitor
    /// User chose "Manage Worktrees…" in the repo picker. Opens the
    /// inspector sheet seeded with the current sessions snapshot so
    /// classification doesn't race with concurrent session edits.
    case openWorktreeJanitor(repositoryID: Repository.ID, repositoryName: String)
    case worktreeJanitor(PresentationAction<WorktreeJanitorFeature.Action>)

    case delegate(Delegate)
  }

  @CasePathable
  enum Delegate: Equatable {
    case prioritySessionTerminated(title: String, body: String)
    /// Emitted when a tray card asks to open the Settings window on a
    /// specific section (e.g. the stale-hooks card routes to Coding Agents).
    /// AppFeature listens and forwards to SettingsFeature.
    case openSettingsRequested(section: SettingsSection)
    /// `worktreeID` is the session's state-key worktree — used for tab
    /// destruction and (when `deleteBackingWorktree` is true) for backing
    /// worktree cleanup. `additionalWorktreeIDsToDelete` carries any
    /// *other* worktrees this session created during its lifetime (e.g.
    /// the convert-to-worktree popover), which outlive the original
    /// state key and still need cleanup.
    case sessionRemoved(
      sessionID: AgentSession.ID,
      repositoryID: Repository.ID,
      worktreeID: Worktree.ID,
      deleteBackingWorktree: Bool,
      additionalWorktreeIDsToDelete: [Worktree.ID]
    )
  }

  @Dependency(TerminalClient.self) var terminalClient
  @Dependency(AutoObserverClient.self) var autoObserverClient
  @Dependency(SessionReferenceScannerClient.self) var scannerClient
  @Dependency(GithubCLIClient.self) var githubCLI
  @Dependency(BackgroundInferenceClient.self) var backgroundInferenceClient
  @Dependency(SupacoolWorktreePruneClient.self) var supacoolWorktreePrune
  @Dependency(RemoteSpawnClient.self) var remoteSpawnClient
  @Dependency(GitClientDependency.self) var gitClient
  @Dependency(\.uuid) var uuid

  /// How long a PR state lookup stays fresh. Refreshing more often than
  /// this rate-limits unnecessary `gh pr view` calls when the user is
  /// bouncing between cards. 60 s is a reasonable compromise between
  /// "current enough" and "don't spam the API".
  private static let prStateCacheWindow: TimeInterval = 60

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .createSession(let session):
        state.$sessions.withLock { $0.append(session) }
        // Surface a short-lived "Starting session" tray card so the user
        // sees the spawn is underway without having to hunt the new card
        // on a crowded board. The card clears on the first busy transition
        // (= agent is actually running) or via × dismiss. Card id is
        // anchored to `session.id` so lookups are trivial and tests stay
        // deterministic without injecting a `uuid` dependency.
        let creatingCard = TrayCard(
          id: session.id,
          kind: .sessionCreating(sessionID: session.id, displayName: session.displayName)
        )
        state.trayCards.append(creatingCard)
        // Intentionally do NOT focus the new session. Spawning an agent
        // is background work; the user stays on the board and sees the
        // new card appear in "In Progress." They can tap in when ready.
        return autoDisplayNameEffect(for: session)

      case .renameSession(let id, let newName):
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }
        state.$sessions.withLock { sessions in
          guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
          sessions[index].displayName = trimmed
        }
        return .none

      case .togglePriority(let id):
        state.$sessions.withLock { sessions in
          guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
          sessions[index].isPriority.toggle()
        }
        return .none

      case .removeSession(let id):
        guard let session = state.sessions.first(where: { $0.id == id }) else {
          return .none
        }
        // Primary backing-worktree cleanup: applies to sessions that own
        // their original worktree (created via the New Terminal sheet's
        // `.newBranch` flow, which sets `removeBackingWorktreeOnDelete`).
        let deleteBackingWorktree =
          session.removeBackingWorktreeOnDelete
          && session.worktreeID != session.repositoryID
          && !Self.sessionsUsingWorkspace(
            session.worktreeID, excluding: id, sessions: state.sessions
          )
        // Converted-worktree cleanup: the convert-to-worktree popover
        // creates a fresh branch+worktree on disk while leaving the
        // session's immutable `worktreeID` anchored at the repo root.
        // Clean that up on delete so we don't leave a dangling worktree
        // whenever the user trashes a converted repo-root session.
        let convertedPath = session.currentWorkspacePath
        let hasConvertedWorkspace =
          convertedPath != session.worktreeID
          && convertedPath != session.repositoryID
        let deleteConvertedWorkspace =
          hasConvertedWorkspace
          && !Self.sessionsUsingWorkspace(
            convertedPath, excluding: id, sessions: state.sessions
          )
        let additionalDeletes: [Worktree.ID] =
          deleteConvertedWorkspace ? [convertedPath] : []
        state.$sessions.withLock { $0.removeAll(where: { $0.id == id }) }
        if state.focusedSessionID == id {
          state.focusedSessionID = nil
        }
        // A session removed before its first busy transition leaves a
        // "Starting session" card behind — clean it up so the tray
        // doesn't accumulate stale progress indicators.
        state.trayCards.removeAll { card in
          if case .sessionCreating(let sessionID, _) = card.kind {
            return sessionID == id
          }
          return false
        }
        return .send(
          .delegate(
            .sessionRemoved(
              sessionID: session.id,
              repositoryID: session.repositoryID,
              worktreeID: session.worktreeID,
              deleteBackingWorktree: deleteBackingWorktree,
              additionalWorktreeIDsToDelete: additionalDeletes
            )
          )
        )

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

      case .prioritySessionTerminated(let id, let status):
        guard status == .detached || status == .interrupted,
          let session = state.sessions.first(where: { $0.id == id }),
          session.isPriority
        else {
          return .none
        }
        let alert = PriorityTerminationAlertState(
          id: uuid(),
          sessionID: id,
          displayName: session.displayName,
          status: status
        )
        state.priorityTerminationAlert = alert
        return .send(.delegate(.prioritySessionTerminated(title: alert.title, body: alert.message)))

      case .dismissPriorityTerminationAlert:
        state.priorityTerminationAlert = nil
        return .none

      case .updateSessionBusyState(let id, let busy):
        state.$sessions.withLock { sessions in
          guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
          guard sessions[index].lastKnownBusy != busy else { return }
          sessions[index].lastKnownBusy = busy
          sessions[index].lastBusyTransitionAt = Date()
          sessions[index].lastActivityAt = Date()
        }
        // First observed busy=true means the PTY spawned and the agent is
        // actually running — auto-dismiss the "Starting session" card.
        if busy {
          state.trayCards.removeAll { card in
            if case .sessionCreating(let sessionID, _) = card.kind {
              return sessionID == id
            }
            return false
          }
        }
        return .none

      case .focusSession(let id):
        state.focusedSessionID = id
        return .none

      case .parkSession(let id, let repositories):
        guard let session = state.sessions.first(where: { $0.id == id }) else {
          return .none
        }
        state.$sessions.withLock { sessions in
          guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
          sessions[index].parked = true
          sessions[index].lastKnownBusy = false
          sessions[index].lastBusyTransitionAt = nil
          sessions[index].lastActivityAt = Date()
        }
        // Drop focus if we're parking the focused session.
        if state.focusedSessionID == id {
          state.focusedSessionID = nil
        }
        // Destroy the PTY so the session stops consuming resources.
        // We build the worktree value the same way the resume paths do,
        // pinning .id to session.worktreeID so the terminal manager's
        // state lookup hits the right key.
        guard let repository = repositories.first(where: { $0.id == session.repositoryID }) else {
          return .none
        }
        let worktree = Self.resumeWorktree(for: session, repository: repository)
        return .run { _ in
          await terminalClient.send(
            .destroyTab(worktree, tabID: TerminalTabID(rawValue: id))
          )
        }

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

      case .openNewTerminalSheetInheritingFrom(let id, let repositories):
        let available = IdentifiedArray(uniqueElements: repositories)
        if let session = state.sessions.first(where: { $0.id == id }) {
          state.newTerminalSheet = NewTerminalFeature.State(
            availableRepositories: available,
            inheritingFrom: session
          )
        } else {
          state.newTerminalSheet = NewTerminalFeature.State(availableRepositories: available)
        }
        return .none

      case .resumeDetachedSession(let id, let repositories):
        guard let session = state.sessions.first(where: { $0.id == id }) else {
          return .none
        }
        guard let sessionID = session.agentNativeSessionID, !sessionID.isEmpty else {
          return .send(.resumeFailed(id: id, message: "No captured session id to resume."))
        }
        guard let agent = session.agent else {
          return .send(.resumeFailed(id: id, message: "Shell sessions can't be resumed."))
        }
        guard let repository = repositories.first(where: { $0.id == session.repositoryID }) else {
          return .send(.resumeFailed(id: id, message: "Repository no longer registered."))
        }
        // CRITICAL: the worktree object we pass to the terminal client MUST
        // have `id == session.worktreeID`. `WorktreeTerminalManager` keys its
        // `states` dictionary by `worktree.id`, and `FullScreenTerminalView`
        // probes that dictionary with `session.worktreeID` verbatim. Supacode
        // may discover a worktree record with a slightly different id (e.g.
        // trailing-slash normalization), so if we picked up that record here
        // the tab would land under a different key and the detached view
        // would never resolve it — looking like "resume does nothing".
        let worktree = Self.resumeWorktree(for: session, repository: repository)
        // Reset transient status so the card immediately reflects the new run.
        state.$sessions.withLock { sessions in
          guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
          sessions[index].lastKnownBusy = false
          sessions[index].lastBusyTransitionAt = nil
          sessions[index].lastActivityAt = Date()
          sessions[index].parked = false
        }
        state.focusedSessionID = id
        let command =
          agent.resumeCommand(sessionID: sessionID, bypassPermissions: Self.readBypassPermissions())
          + "\r"
        return .run { _ in
          await terminalClient.send(
            .createTabWithInput(
              worktree,
              input: command,
              runSetupScriptIfNew: false,
              id: id
            )
          )
        }

      case .resumeDetachedSessionWithPicker(let id, let repositories):
        guard let session = state.sessions.first(where: { $0.id == id }) else {
          return .none
        }
        guard let agent = session.agent else {
          return .send(.resumeFailed(id: id, message: "Shell sessions can't be resumed."))
        }
        guard let repository = repositories.first(where: { $0.id == session.repositoryID }) else {
          return .send(.resumeFailed(id: id, message: "Repository no longer registered."))
        }
        let worktree = Self.resumeWorktree(for: session, repository: repository)
        state.$sessions.withLock { sessions in
          guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
          sessions[index].lastKnownBusy = false
          sessions[index].lastBusyTransitionAt = nil
          sessions[index].lastActivityAt = Date()
          sessions[index].parked = false
        }
        state.focusedSessionID = id
        let command =
          agent.resumePickerCommand(bypassPermissions: Self.readBypassPermissions()) + "\r"
        return .run { _ in
          await terminalClient.send(
            .createTabWithInput(
              worktree,
              input: command,
              runSetupScriptIfNew: false,
              id: id
            )
          )
        }

      case .resumeFailed(let id, let message):
        boardLogger.warning("Resume failed for session \(id): \(message)")
        return .none

      case .reconnectRemoteSession(let id):
        guard
          let session = state.sessions.first(where: { $0.id == id }),
          let workspaceID = session.remoteWorkspaceID,
          let workspace = state.remoteWorkspaces.first(where: { $0.id == workspaceID }),
          let host = state.remoteHosts.first(where: { $0.id == workspace.hostID }),
          let tmuxSessionName = session.tmuxSessionName
        else {
          return .send(._reconnectFailed(id: id, message: "Remote session metadata is missing."))
        }
        guard let localSocketPath = terminalClient.hookSocketPath() else {
          return .send(._reconnectFailed(id: id, message: "Agent hook socket isn't running."))
        }
        // Reset the disconnected flag and stamp activity so the card
        // flips out of `.disconnected` as soon as the surface comes up.
        state.$sessions.withLock { sessions in
          guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
          sessions[index].remoteConnectionLost = false
          sessions[index].lastKnownBusy = false
          sessions[index].lastBusyTransitionAt = nil
          sessions[index].lastActivityAt = Date()
        }
        let invocation = RemoteSpawnInvocation(
          sshAlias: host.sshAlias,
          user: host.connection.user,
          hostname: host.connection.hostname,
          port: host.connection.port,
          identityFile: host.connection.identityFile,
          deferToSSHConfig: host.deferToSSHConfig,
          remoteWorkingDirectory: workspace.remoteWorkingDirectory,
          remoteSocketPath: Self.remoteSocketPath(for: id, host: host),
          localSocketPath: localSocketPath,
          tmuxSessionName: tmuxSessionName,
          worktreeID: session.worktreeID,
          tabID: id,
          surfaceID: id,
          agentCommand: session.agent.map { Self.remoteAgentCommand(for: $0, session: session) },
          agent: session.agent
        )
        let sshCommand = remoteSpawnClient.sshInvocation(invocation)
        let worktree = Self.remoteShimWorktree(for: session)
        // Ensure the old (dead) tab entry is gone before the new spawn,
        // so `createRemoteTab` re-registers under the same UUID without
        // colliding with the stale one.
        return .run { _ in
          await terminalClient.send(.destroyTab(worktree, tabID: TerminalTabID(rawValue: id)))
          await terminalClient.send(.createRemoteTab(worktree, command: sshCommand, id: id))
        }

      case ._reconnectFailed(let id, let message):
        boardLogger.warning("Remote reconnect failed for session \(id): \(message)")
        return .none

      case .convertSessionToWorktree(let id, let branchName, let repositories):
        let trimmedBranch = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBranch.isEmpty,
          let session = state.sessions.first(where: { $0.id == id }),
          let repository = repositories.first(where: { $0.id == session.repositoryID })
        else {
          return .none
        }
        let repoRoot = repository.rootURL
        let worktreeID = session.worktreeID
        let tabID = TerminalTabID(rawValue: session.id)
        return .run { [gitClient, terminalClient] send in
          do {
            let baseDirectory = SupacodePaths.worktreeBaseDirectory(
              for: repoRoot,
              globalDefaultPath: nil,
              repositoryOverridePath: nil
            )
            let worktree = try await gitClient.createWorktree(
              trimmedBranch,
              repoRoot,
              baseDirectory,
              false,
              false,
              ""
            )
            await send(
              ._convertSessionToWorktreeSucceeded(
                id: id,
                newWorkspacePath: worktree.id
              )
            )
            let escapedPath = worktree.id.replacingOccurrences(of: "'", with: "'\\''")
            await terminalClient.send(
              .sendText(
                worktreeID: worktreeID,
                tabID: tabID,
                text: "cd '\(escapedPath)'"
              )
            )
          } catch {
            await send(
              ._convertSessionToWorktreeFailed(
                id: id,
                message: error.localizedDescription
              )
            )
          }
        }

      case ._convertSessionToWorktreeSucceeded(let id, let newWorkspacePath):
        state.$sessions.withLock { sessions in
          guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
          sessions[index].currentWorkspacePath = newWorkspacePath
        }
        return .none

      case ._convertSessionToWorktreeFailed(let id, let message):
        boardLogger.warning("Convert to worktree failed for session \(id): \(message)")
        return .none

      case .rerunDetachedSession(let id, let repositories):
        guard let previous = state.sessions.first(where: { $0.id == id }) else {
          return .none
        }
        // Pop focus so the user lands on the sheet with the board
        // behind it. Crucially, do NOT remove the previous session
        // here — wait until the new session is created. A failed
        // create or a cancelled sheet would otherwise lose the
        // original card and its prompt.
        state.pendingRerunSessionID = previous.id
        state.focusedSessionID = nil
        state.newTerminalSheet = NewTerminalFeature.State(
          availableRepositories: IdentifiedArray(uniqueElements: repositories),
          rerunFrom: previous
        )
        return .none

      case .toggleAutoObserver(let id):
        var nowEnabled = false
        state.$sessions.withLock { sessions in
          guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
          sessions[index].autoObserver.toggle()
          nowEnabled = sessions[index].autoObserver
        }
        // Fire an immediate trigger when toggling on so the observer can
        // respond to whatever's already on screen (a permission prompt
        // or a completed message). Without this, the user has to wait
        // for the next busy→idle / awaiting-input transition.
        return nowEnabled ? .send(.autoObserverTriggered(id: id)) : .none

      case .setAutoObserverPrompt(let id, let prompt):
        state.$sessions.withLock { sessions in
          guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
          sessions[index].autoObserverPrompt = prompt
        }
        return .none

      case .autoObserverTriggered(let id):
        guard
          let session = state.sessions.first(where: { $0.id == id }),
          session.autoObserver,
          !state.autoObserverInFlight.contains(id)
        else { return .none }
        state.autoObserverInFlight.insert(id)
        let worktreeID = session.worktreeID
        let tabID = TerminalTabID(rawValue: id)
        let userInstructions = session.autoObserverPrompt
        return .run { [autoObserverClient] send in
          let screen = await terminalClient.readScreenContents(worktreeID, tabID)
          guard let screen, !screen.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            await send(._autoObserverDecided(id: id, response: nil))
            return
          }
          let response = await autoObserverClient.decide(screen, userInstructions)
          await send(._autoObserverDecided(id: id, response: response))
        }

      case ._autoObserverDecided(let id, let response):
        state.autoObserverInFlight.remove(id)
        guard
          let response,
          let session = state.sessions.first(where: { $0.id == id }),
          session.autoObserver
        else { return .none }
        let worktreeID = session.worktreeID
        let tabID = TerminalTabID(rawValue: id)
        // Append newline so the response is submitted like pressing Enter.
        let text = response.hasSuffix("\n") ? response : response + "\n"
        return .run { _ in
          await terminalClient.send(.sendText(worktreeID: worktreeID, tabID: tabID, text: text))
        }

      case .newTerminalSheet(.presented(.delegate(.created(let session)))):
        state.newTerminalSheet = nil
        // The rerun's replacement is ready — drop the original now.
        if let pendingID = state.pendingRerunSessionID {
          state.$sessions.withLock { $0.removeAll(where: { $0.id == pendingID }) }
          state.pendingRerunSessionID = nil
        }
        return .send(.createSession(session))

      case .newTerminalSheet(.presented(.delegate(.cancel))):
        state.newTerminalSheet = nil
        // Cancelled / dismissed without creating — keep the original.
        state.pendingRerunSessionID = nil
        return .none

      case .newTerminalSheet(.dismiss):
        // Sheet dismissed by the framework (Esc, click-outside, etc.)
        // without a delegate action firing — clear any pending rerun
        // marker so a later non-rerun create doesn't drop the wrong
        // session.
        state.pendingRerunSessionID = nil
        return .none

      case .cardAppeared(let id):
        guard let session = state.sessions.first(where: { $0.id == id }) else {
          return .none
        }
        // Re-scan when the references cache is missing OR the session has
        // had activity since the last scan. This keeps PR state fresh after
        // the agent writes something new without spamming scans on every
        // board render.
        let needsScan = session.referencesScannedAt == nil
          || session.lastActivityAt > (session.referencesScannedAt ?? .distantPast)
        // Also kick off PR status refresh for any PRs in the current cache,
        // throttled by the cache window.
        let cacheWindow = Self.prStateCacheWindow
        let shouldRefreshPRs =
          session.referencesScannedAt.map { Date().timeIntervalSince($0) > cacheWindow } ?? true
        let worktreeID = session.worktreeID
        let agentID = session.agentNativeSessionID
        let initialPrompt = session.initialPrompt
        let prRefs = shouldRefreshPRs
          ? session.references.filter {
              if case .pullRequest = $0 { return true } else { return false }
            }
          : []

        var effects: [Effect<Action>] = []
        if needsScan {
          effects.append(
            .run { [scannerClient] send in
              var refs: [SessionReference] = []
              if let agentID, !agentID.isEmpty {
                refs = await scannerClient.scan(worktreeID, agentID)
              }
              // Always also scan the initialPrompt — covers Codex sessions
              // with no JSONL, and catches tickets the user typed before
              // any Claude hook fired.
              let promptRefs = scannerClient.scanText(initialPrompt)
              let merged = Self.mergeReferences(refs, with: promptRefs)
              await send(._referencesScanned(id: id, refs: merged))
            }
          )
        }
        for ref in prRefs {
          effects.append(.send(._refreshPRStatus(id: id, ref: ref)))
        }
        return .merge(effects)

      case ._referencesScanned(let id, let refs):
        state.$sessions.withLock { sessions in
          guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
          sessions[index].references = Self.mergeReferences(
            refs,
            with: sessions[index].references,
            preferNewStates: true
          )
          sessions[index].referencesScannedAt = Date()
        }
        // Kick off PR status fetches for any PR refs we just discovered.
        guard let updated = state.sessions.first(where: { $0.id == id }) else {
          return .none
        }
        let prRefs = updated.references.filter {
          if case .pullRequest(_, _, _, let s) = $0 { return s == nil } else { return false }
        }
        return .merge(prRefs.map { .send(._refreshPRStatus(id: id, ref: $0)) })

      case ._refreshPRStatus(let id, let ref):
        guard case .pullRequest(let owner, let repo, let number, _) = ref else {
          return .none
        }
        return .run { [githubCLI] send in
          do {
            let newState = try await githubCLI.viewPullRequest(owner, repo, number)
            await send(._prStatusUpdated(id: id, ref: ref, state: newState))
          } catch {
            boardLogger.warning(
              "Failed to fetch PR state for \(owner)/\(repo)#\(number): \(error)"
            )
          }
        }

      case ._prStatusUpdated(let id, let ref, let newState):
        state.$sessions.withLock { sessions in
          guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
          sessions[index].references = sessions[index].references.map { existing in
            existing.dedupeKey == ref.dedupeKey
              ? Self.updatingPRState(of: existing, to: newState)
              : existing
          }
        }
        return .none

      case ._autoDisplayNameSuggested(let id, let suggested):
        state.$sessions.withLock { sessions in
          guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
          // Only apply the LLM suggestion if the name is still the
          // deterministic slice we started with. If the user renamed
          // (or NewTerminalFeature pinned a PR title) in the meantime,
          // leave their choice alone.
          let derived = AgentSession.deriveDisplayName(
            from: sessions[index].initialPrompt,
            fallbackID: sessions[index].id
          )
          guard sessions[index].displayName == derived else { return }
          sessions[index].displayName = suggested
        }
        return .none

      case .pruneWorktreesRequested(let repositoryID, let repositoryName):
        return pruneWorktreesEffect(
          repositoryID: repositoryID,
          repositoryName: repositoryName,
          sessions: state.sessions
        )

      case ._pruneWorktreesResult(let summary):
        state.pruneAlert = summary
        return .none

      case .confirmPruneOrphans(let sessionIDs):
        state.pruneAlert = nil
        // Chain one .removeSession per orphan id. `.removeSession` is the
        // existing cleanup path — it handles focus clearing and the
        // sessionRemoved delegate (which normally triggers worktree
        // deletion, harmless here since git's prune already removed the
        // record and the directory's already gone).
        return .run { send in
          for id in sessionIDs {
            await send(.removeSession(id: id))
          }
        }

      case .dismissPruneAlert:
        state.pruneAlert = nil
        return .none

      case .trayCardPushed(let card):
        // De-dupe by kind so repeated pushes of the same logical card
        // (e.g. stale-hooks on every launch) don't stack.
        if state.trayCards.contains(where: { $0.kind == card.kind }) {
          return .none
        }
        state.trayCards.append(card)
        return .none

      case .trayCardDismissed(let id):
        state.trayCards.remove(id: id)
        return .none

      case .trayCardPrimaryTapped(let id):
        guard let card = state.trayCards[id: id] else { return .none }
        switch card.kind {
        case .staleHooks:
          state.trayCards.remove(id: id)
          return .send(.delegate(.openSettingsRequested(section: .codingAgents)))
        case .sessionCreating(let sessionID, _):
          state.trayCards.remove(id: id)
          return .send(.focusSession(id: sessionID))
        }

      case .openWorktreeJanitor(let repositoryID, let repositoryName):
        state.worktreeJanitor = WorktreeJanitorFeature.State(
          repositoryID: repositoryID,
          repositoryName: repositoryName,
          sessionsSnapshot: state.sessions
        )
        return .none

      case .worktreeJanitor(.presented(.delegate(.dismissed))):
        state.worktreeJanitor = nil
        return .none

      case .worktreeJanitor:
        return .none

      case .delegate:
        return .none

      case .newTerminalSheet:
        return .none
      }
    }
    .ifLet(\.$newTerminalSheet, action: \.newTerminalSheet) {
      NewTerminalFeature()
    }
    .ifLet(\.$worktreeJanitor, action: \.worktreeJanitor) {
      WorktreeJanitorFeature()
    }
  }

  /// Build the `Worktree` value handed to `TerminalClient` when resuming. The
  /// returned `worktree.id` is pinned to `session.worktreeID` verbatim so the
  /// new tab lands under the same key the detached view probes for.
  /// True when any session other than the one being removed still has
  /// the given path as either its state anchor (`worktreeID`) or its
  /// current workspace. Used by `removeSession` to avoid deleting a
  /// worktree directory that another session depends on.
  nonisolated fileprivate static func sessionsUsingWorkspace(
    _ path: Worktree.ID,
    excluding excludedID: AgentSession.ID,
    sessions: [AgentSession]
  ) -> Bool {
    sessions.contains { other in
      other.id != excludedID
        && (other.worktreeID == path || other.currentWorkspacePath == path)
    }
  }

  /// Current value of the New Terminal sheet's "Skip permission prompts"
  /// toggle. Mirrored via @AppStorage in the view layer; the reducer
  /// reads it on demand so resume paths stay in sync with whatever the
  /// user last chose, without threading the flag through state.
  fileprivate static func readBypassPermissions() -> Bool {
    UserDefaults.standard.object(forKey: "supacool.bypassPermissions") as? Bool ?? true
  }

  /// Merge two reference lists, deduping by `dedupeKey`. When
  /// `preferNewStates` is true, PR state from the new list wins; otherwise
  /// the first occurrence wins. Used to combine JSONL + prompt scans.
  nonisolated fileprivate static func mergeReferences(
    _ primary: [SessionReference],
    with secondary: [SessionReference],
    preferNewStates: Bool = false
  ) -> [SessionReference] {
    var merged: [SessionReference] = []
    var seen = Set<String>()
    for ref in primary + secondary {
      let key = ref.dedupeKey
      if seen.insert(key).inserted {
        merged.append(ref)
      } else if preferNewStates,
        case .pullRequest(_, _, _, let newState) = ref,
        newState != nil,
        let idx = merged.firstIndex(where: { $0.dedupeKey == key }),
        case .pullRequest(let o, let r, let n, _) = merged[idx]
      {
        merged[idx] = .pullRequest(owner: o, repo: r, number: n, state: newState)
      }
    }
    return merged
  }

  /// Returns a copy of `ref` with its PR state replaced. No-op for ticket refs.
  nonisolated fileprivate static func updatingPRState(
    of ref: SessionReference,
    to newState: PRState
  ) -> SessionReference {
    if case .pullRequest(let owner, let repo, let number, _) = ref {
      return .pullRequest(owner: owner, repo: repo, number: number, state: newState)
    }
    return ref
  }

  // MARK: - Remote helpers

  /// Remote-side socket path the reverse-forward binds to. Per-session so
  /// concurrent remote tabs don't fight over a single path. Lives under
  /// `/tmp` so cleanup on remote reboot is automatic.
  fileprivate static func remoteSocketPath(for id: AgentSession.ID, host: RemoteHost) -> String {
    let short = id.uuidString.lowercased().prefix(12)
    let dir = host.overrides.effectiveRemoteTmpdir
    return "\(dir)/supacool-hook-\(short).sock"
  }

  /// Synthesizes the `Worktree` value the terminal manager keys by for
  /// remote sessions. `id` must match `session.worktreeID` so the
  /// existing classifier lookups land on the right key.
  fileprivate static func remoteShimWorktree(for session: AgentSession) -> Worktree {
    Worktree(
      id: session.worktreeID,
      name: session.displayName,
      detail: "",
      workingDirectory: URL(fileURLWithPath: "/"),
      repositoryRootURL: URL(fileURLWithPath: "/")
    )
  }

  /// The command string tmux exec's on the remote for a given agent.
  /// Uses the agent's existing run/resume helpers so local and remote
  /// stay in lockstep; falls back to a fresh run for agents without a
  /// captured session id.
  fileprivate static func remoteAgentCommand(
    for agent: AgentType,
    session: AgentSession
  ) -> String {
    let bypass = readBypassPermissions()
    if let resumeID = session.agentNativeSessionID, !resumeID.isEmpty {
      return agent.resumeCommand(sessionID: resumeID, bypassPermissions: bypass)
    }
    return agent.command(prompt: session.initialPrompt, bypassPermissions: bypass)
  }

  fileprivate static func resumeWorktree(
    for session: AgentSession,
    repository: Repository
  ) -> Worktree {
    let workingDirectory: URL = {
      if let existing = repository.worktrees.first(where: { $0.id == session.worktreeID }) {
        return existing.workingDirectory
      }
      return URL(fileURLWithPath: session.worktreeID).standardizedFileURL
    }()
    return Worktree(
      id: session.worktreeID,
      name: workingDirectory.lastPathComponent,
      detail: "",
      workingDirectory: workingDirectory,
      repositoryRootURL: repository.rootURL.standardizedFileURL
    )
  }

  // MARK: - Auto display name

  /// Kick off a background LLM call to turn the session's prompt into a
  /// short, human title. Returns `.none` for the obvious skip cases:
  /// empty prompt, short prompt (deterministic slice is already fine),
  /// or a custom name the sheet pinned (e.g. PR title from the
  /// pasted-PR-URL flow).
  private func autoDisplayNameEffect(for session: AgentSession) -> Effect<Action> {
    let prompt = session.initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty else { return .none }

    // If NewTerminalFeature pinned a custom displayName, don't clobber it.
    let derived = AgentSession.deriveDisplayName(from: prompt, fallbackID: session.id)
    guard session.displayName == derived else { return .none }

    // For short prompts the deterministic slice is already the full
    // text — no point spending an inference call to re-phrase "fix the
    // login bug" into something else.
    let wordCount = prompt.split(whereSeparator: \.isWhitespace).count
    guard wordCount >= 4 else { return .none }

    let inferencePrompt = """
      Summarize this coding task as a short title: 3 to 6 words, Title Case, no quotes, no trailing period.
      Reply with ONLY the title — nothing else, no explanation.

      Task:
      \(prompt)
      """

    let sessionID = session.id
    return .run { [backgroundInferenceClient] send in
      do {
        let raw = try await backgroundInferenceClient.infer(inferencePrompt)
        let title = sanitizeSessionTitle(raw)
        guard !title.isEmpty else { return }
        await send(._autoDisplayNameSuggested(id: sessionID, suggested: title))
      } catch {
        // Quiet fallback — the deterministic name stays. A background
        // inference failure isn't worth bothering the user about.
      }
    }
    .cancellable(id: AutoDisplayNameCancelID(sessionID: sessionID), cancelInFlight: true)
  }

  // MARK: - Worktree prune

  /// Run `git worktree prune --verbose` for the given repo, compute any
  /// Supacool sessions whose backing directory has disappeared, and
  /// surface a summary alert with both. Cancel-in-flight on the same
  /// repo so rapid re-clicks collapse into one attempt.
  private func pruneWorktreesEffect(
    repositoryID: Repository.ID,
    repositoryName: String,
    sessions: [AgentSession]
  ) -> Effect<Action> {
    let alertID = UUID()
    return .run { [supacoolWorktreePrune] send in
      do {
        let result = try await supacoolWorktreePrune.prune(URL(fileURLWithPath: repositoryID))
        let orphans = findOrphanSessionIDs(in: sessions, repositoryID: repositoryID)
        await send(
          ._pruneWorktreesResult(
            .init(
              id: alertID,
              repositoryID: repositoryID,
              repositoryName: repositoryName,
              outcome: .success(
                prunedCount: result.prunedRefs.count,
                orphanSessionIDs: orphans
              )
            )
          )
        )
      } catch {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        await send(
          ._pruneWorktreesResult(
            .init(
              id: alertID,
              repositoryID: repositoryID,
              repositoryName: repositoryName,
              outcome: .failure(
                message: message.isEmpty ? "git worktree prune failed." : message
              )
            )
          )
        )
      }
    }
    .cancellable(id: PruneWorktreesCancelID(repositoryID: repositoryID), cancelInFlight: true)
  }
}

// MARK: - Auto display name helpers

private nonisolated struct AutoDisplayNameCancelID: Hashable, Sendable {
  let sessionID: AgentSession.ID
}

// MARK: - Worktree prune helpers

private nonisolated struct PruneWorktreesCancelID: Hashable, Sendable {
  let repositoryID: Repository.ID
}

/// Collect session ids in the given repo whose backing worktree
/// directory no longer exists on disk. Sessions running at the repo root
/// (worktreeID == repositoryID) are skipped — the repo itself is the
/// "worktree" there and can't go stale independently.
nonisolated func findOrphanSessionIDs(
  in sessions: [AgentSession],
  repositoryID: Repository.ID
) -> [AgentSession.ID] {
  sessions
    .filter { $0.repositoryID == repositoryID }
    .filter { $0.worktreeID != $0.repositoryID }
    .filter { !FileManager.default.fileExists(atPath: $0.worktreeID) }
    .map(\.id)
}

/// Clean up an LLM response intended to be a short session title.
/// Strips surrounding quotes/backticks, drops trailing periods, collapses
/// multi-line output to the first non-empty line, and caps length.
nonisolated func sanitizeSessionTitle(_ raw: String) -> String {
  let firstLine =
    raw.split(whereSeparator: \.isNewline)
    .map(String.init)
    .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
    ?? raw
  var result = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
  while let first = result.first, ["\"", "'", "`"].contains(first) {
    result.removeFirst()
  }
  while let last = result.last, ["\"", "'", "`"].contains(last) {
    result.removeLast()
  }
  result = result.trimmingCharacters(in: .whitespaces)
  while result.hasSuffix(".") { result.removeLast() }
  return String(result.prefix(60))
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
