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
    @Shared(.bookmarks) var bookmarks: [Bookmark] = []
    /// Half-finished "new terminal" prompts. Surfaced as a slim row at
    /// the top of the board; tap reopens the sheet pre-filled, launching
    /// from the sheet consumes the draft.
    @Shared(.drafts) var drafts: [Draft] = []
    /// Cards the user removed in the last 3 days. The sweeper at app
    /// launch nukes everything older; restore moves an entry back to
    /// `sessions`. Persisted so quitting + relaunching doesn't lose
    /// the recovery window.
    @Shared(.trashedSessions) var trashedSessions: [TrashedSession] = []

    /// Bookmark pills currently spawning a session. These stay disabled
    /// until the spawn finishes (success or failure) so repeat-clicks
    /// don't fan out duplicate sessions.
    var bookmarkSpawnInFlight: Set<Bookmark.ID> = []

    /// Whether the trash sheet is open (browse + restore + permanent delete).
    var isTrashSheetPresented: Bool = false

    /// When non-nil, the root view shows this session's terminal full-screen
    /// instead of the board. Not persisted — fresh launches always land on
    /// the board.
    var focusedSessionID: AgentSession.ID?

    /// The new-terminal sheet state, if open.
    @Presents var newTerminalSheet: NewTerminalFeature.State?

    /// "Debug this session…" sheet, if open. Captures a free-text
    /// observation from the user before BoardFeature spawns a debug
    /// agent in the supacool repo primed with the source trace.
    @Presents var debugSheet: DebugSessionFeature.State?

    /// Repositories snapshot captured at sheet-open time so the spawn
    /// handler can look up the supacool repo without the parent having
    /// to re-pass them. Cleared when the sheet closes.
    var pendingDebugRepositories: [Repository] = []

    /// Worktree janitor state embedded in the trash dialog's
    /// "Worktrees" tab. Holds the currently selected repository scan.
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

    /// Presented when the New Terminal create flow detected that the
    /// requested branch is already checked out at a *different* path —
    /// `git worktree add` would otherwise fail. The alert lets the user
    /// reuse the existing checkout, delete it and recreate at the
    /// original target, or cancel.
    var worktreeConflictAlert: WorktreeConflictAlertState?

    /// Transient cards floating in the bottom-right tray over the board.
    /// Not persisted — refilled on each app launch by whichever subsystem
    /// owns the signal (stale hooks check, New Terminal drafts, etc.).
    var trayCards: IdentifiedArrayOf<TrayCard> = []

    /// First-launch Getting Started carousel state. `isPresented` is
    /// session-only; it flips true the first time app-launch evaluation
    /// finds any incomplete, non-skipped tasks, and flips false as soon
    /// as the list empties (all completed or skipped) or the user
    /// dismisses the panel. See `GettingStartedState`.
    var gettingStarted: GettingStartedState = GettingStartedState()

    /// Raw values of tasks the user has explicitly parked via Skip.
    /// Persisted so the carousel doesn't nag on every relaunch. Cleared
    /// by `gettingStartedShowAgain` (wired to a Settings button) so the
    /// user can bring the panel back on demand. Stored as `[String]`
    /// because `@Shared(.appStorage(...))` plays nicer with arrays than
    /// sets — the reducer treats it as a set via conversion.
    @Shared(.appStorage("gettingStartedSkippedTasks"))
    var skippedGettingStartedTasks: [String] = []
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

  /// Captured at the moment SessionSpawner reports the
  /// `branchAlreadyCheckedOut` error so the alert can offer Reuse /
  /// Delete & recreate / Cancel without re-running git work to find
  /// the conflicting worktree. Carries the original `LocalRequest` so
  /// "Delete & recreate" can resubmit unchanged.
  struct WorktreeConflictAlertState: Equatable, Identifiable, Sendable {
    let id: UUID
    let sessionID: AgentSession.ID
    let placeholderDisplayName: String
    let request: SessionSpawner.LocalRequest
    let branch: String
    let existingWorktree: Worktree

    init(
      id: UUID = UUID(),
      sessionID: AgentSession.ID,
      placeholderDisplayName: String,
      request: SessionSpawner.LocalRequest,
      branch: String,
      existingWorktree: Worktree
    ) {
      self.id = id
      self.sessionID = sessionID
      self.placeholderDisplayName = placeholderDisplayName
      self.request = request
      self.branch = branch
      self.existingWorktree = existingWorktree
    }

    var title: String { "Branch already checked out" }

    var message: String {
      "'\(branch)' is already used by a worktree at "
        + "\(existingWorktree.workingDirectory.path(percentEncoded: false)).\n\n"
        + "Reuse the existing worktree, or delete it and create a fresh one?"
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
    /// Browse / manage trashed sessions. Opens the trash sheet.
    case openTrashSheet
    case dismissTrashSheet
    /// User picked Restore on a trashed entry. Re-adds the AgentSession
    /// to `state.sessions` (no live PTY — user picks Rerun/Resume to
    /// reanimate) and removes it from trash.
    case restoreFromTrash(id: AgentSession.ID)
    /// User picked Delete now. Removes from trash and emits
    /// `.sessionRemoved` so AppFeature/RepositoriesFeature do the
    /// worktree cleanup. (PTY tab was destroyed at trash-push time;
    /// destroyTab is idempotent so the redundant call is harmless.)
    case deleteFromTrash(id: AgentSession.ID)
    /// Convenience action: permanent-delete every trashed session.
    case emptyTrash
    /// Internal: fired on app launch. Iterates `trashedSessions`,
    /// permanent-deletes anything past `retentionWindow`.
    case _sweepExpiredTrash
    case togglePriority(id: AgentSession.ID)
    case markSessionActivity(id: AgentSession.ID)
    case markSessionCompletedOnce(id: AgentSession.ID)
    case updateSessionBusyState(id: AgentSession.ID, busy: Bool)
    /// Fired by `SessionStateWatcher` on mount + status transitions.
    /// Used as a fallback to clear "Starting session" cards when a
    /// session is already live but never emits busy=true (e.g. shell).
    case sessionStatusObserved(id: AgentSession.ID, status: BoardSessionStatus)
    case prioritySessionTerminated(id: AgentSession.ID, status: BoardSessionStatus)
    case dismissPriorityTerminationAlert
    /// Park: destroy the PTY to free resources, flag the session as
    /// parked so the board sorts it into the bottom bucket. Metadata
    /// (prompt, captured resume id) is preserved so the user can unpark
    /// via the existing Resume / Rerun paths.
    case parkSession(id: AgentSession.ID, repositories: [Repository])
    /// Park as active: move the session into the parked bucket but keep
    /// its PTY/tab alive. Useful for hiding long-running agents without
    /// interrupting them.
    case parkActiveSession(id: AgentSession.ID)
    /// Clears the parked bit for sessions whose tab is still alive.
    case unparkSession(id: AgentSession.ID)

    // MARK: Focus
    case focusSession(id: AgentSession.ID?)

    // MARK: Repo filter
    case toggleRepository(id: String)
    case focusRepository(id: String)
    case showAllRepositories

    // MARK: New-terminal sheet
    case openNewTerminalSheet(repositories: [Repository])
    /// Opens the new-terminal sheet from a focused session, keeping only
    /// the repository preference. Workspace/branch fields intentionally
    /// start blank so the dialog never reuses the previous worktree.
    case openNewTerminalSheetFromSession(
      id: AgentSession.ID,
      repositories: [Repository]
    )
    case rerunDetachedSession(id: AgentSession.ID, repositories: [Repository])
    case resumeDetachedSession(id: AgentSession.ID, repositories: [Repository])
    /// Raw-shell sessions have no agent-native resume. This reopens the
    /// saved terminal split layout/folders under the same session tab ID.
    case restoreShellSessionLayout(id: AgentSession.ID, repositories: [Repository])
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
    /// Internal: local spawn finished. Replaces the placeholder tray
    /// card and triggers the normal `createSession` flow.
    case _sessionSpawnCompleted(session: AgentSession)
    /// Internal: local spawn failed. Drops the placeholder tray card.
    case _sessionSpawnFailed(sessionID: AgentSession.ID, message: String)
    /// Internal: spawn detected that the requested branch is already
    /// checked out elsewhere. Presents the WorktreeConflictAlert; the
    /// placeholder tray card stays up so the user keeps a visual anchor
    /// while they pick a recovery path.
    case _sessionSpawnConflict(
      sessionID: AgentSession.ID,
      placeholderDisplayName: String,
      request: SessionSpawner.LocalRequest,
      branch: String,
      existing: Worktree
    )
    /// User picked Reuse on the conflict alert: spawn against the
    /// existing worktree directly (no `git worktree add`).
    case worktreeConflictReuseTapped
    /// User picked Delete & recreate: remove the conflicting worktree
    /// and resubmit the original request.
    case worktreeConflictDeleteAndRecreateTapped
    /// User cancelled — drop the placeholder, clear the alert.
    case dismissWorktreeConflictAlert

    // MARK: Bookmarks
    /// One-click launch: resolves a bookmark into a SessionSpawner
    /// request and runs it directly — no sheet.
    case bookmarkTapped(id: Bookmark.ID, repositories: [Repository])
    /// Right-click → Edit. Opens the NewTerminalSheet pre-filled from
    /// the bookmark with `editingBookmarkID` set so submit replaces the
    /// bookmark in-place (and also spawns a session).
    case bookmarkEditRequested(id: Bookmark.ID, repositories: [Repository])
    /// Right-click → Delete. No confirmation dialog for v1 — a
    /// bookmark is cheap to re-create.
    case bookmarkDeleteRequested(id: Bookmark.ID)
    /// Internal success callback from `bookmarkTapped`.
    case _bookmarkSpawnCompleted(session: AgentSession)
    /// Internal failure callback — drops the placeholder tray card.
    case _bookmarkSpawnFailed(bookmarkID: Bookmark.ID, sessionID: AgentSession.ID, message: String)

    // MARK: Drafts
    /// Tap on a draft pill: reopens the New Terminal sheet pre-filled
    /// with the draft's contents. Save Draft inside the sheet updates
    /// in-place; Create consumes the draft via `.draftConsumed`.
    case draftTapped(id: Draft.ID, repositories: [Repository])
    /// Right-click → Delete. No confirmation — re-typing the prompt is
    /// cheap, and undo via the trash sheet would be over-engineering.
    case draftDeleteRequested(id: Draft.ID)

    // MARK: Debug session
    /// Right-click → "Debug session…" on a card. Opens the debug sheet
    /// with the source session captured. `repositories` is forwarded from
    /// the parent so the spawn handler can look up the supacool repo.
    case debugSessionRequested(id: AgentSession.ID, repositories: [Repository])
    /// Sheet child reducer feedback.
    case debugSheet(PresentationAction<DebugSessionFeature.Action>)
    /// Internal: debug session spawn finished.
    case _debugSpawnCompleted(session: AgentSession)
    /// Internal: debug session spawn failed.
    case _debugSpawnFailed(message: String)

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
    /// User tapped a card's secondary button (e.g. "Reinstall" on a
    /// stale-hooks card). Currently only `.staleHooks` defines one; other
    /// kinds no-op. Removing the card is the responsibility of this
    /// handler / the follow-up effect, not a caller responsibility.
    case trayCardSecondaryTapped(id: TrayCard.ID)
    /// User tapped the × on a card. Removes it for the session.
    case trayCardDismissed(id: TrayCard.ID)
    /// Fired by AppFeature when SettingsFeature reports a successful
    /// install for a slot. Narrows any stale-hooks card so the user sees
    /// progress (card shrinks as slots get fixed) and disappears when
    /// the last slot is handled.
    case trayNoteHookInstalled(slot: AgentHookSlot)

    // MARK: Getting Started
    /// Fired by AppFeature after it's re-computed the pending tasks.
    /// Replaces the carousel's task list; presents the panel if the
    /// list is non-empty AND the panel hasn't been dismissed yet this
    /// session.
    case gettingStartedEvaluated(pending: [GettingStartedTask])
    /// View-binding path for the carousel's `scrollPosition(id:)`.
    case gettingStartedSetCurrentIndex(Int)
    /// User tapped the primary Setup button on a card. Routes via
    /// delegate to AppFeature, which knows how to open Settings / the
    /// open-panel / etc.
    case gettingStartedSetupTapped(GettingStartedTask)
    /// User tapped Skip. Parks the task (persisted) and removes it from
    /// the visible list. Advances the page if needed; hides the panel
    /// if this was the last task.
    case gettingStartedSkipTapped(GettingStartedTask)
    /// User tapped ×. Hides the panel for the rest of this session but
    /// leaves the persisted skip set untouched — relaunching brings
    /// untouched tasks back.
    case gettingStartedDismiss
    /// "Show Getting Started Again" button in Settings → General.
    /// Clears the persisted skip set and re-requests evaluation from
    /// AppFeature so the carousel comes back with every incomplete task.
    case gettingStartedShowAgain

    // MARK: Worktree prune
    /// User triggered a manual prune for a repository.
    /// Kicks off `git worktree prune --verbose` and surfaces a summary.
    case pruneWorktreesRequested(repositoryID: Repository.ID, repositoryName: String)
    /// Result from the prune effect — populates the summary alert.
    case _pruneWorktreesResult(PruneAlertState)
    /// User hit "Remove orphans" in the summary alert.
    case confirmPruneOrphans(sessionIDs: [AgentSession.ID])
    /// Alert was dismissed (OK / Keep / swipe-away).
    case dismissPruneAlert

    // MARK: Worktree janitor
    /// Open/refresh the janitor for a repository from the trash
    /// dialog's Worktrees tab.
    case openWorktreeJanitor(repositoryID: Repository.ID, repositoryName: String)
    /// Internal follow-up used when switching repositories while an
    /// existing janitor is mounted. Forces a nil transition so child
    /// scan effects are torn down before presenting the new repo.
    case _presentWorktreeJanitor(repositoryID: Repository.ID, repositoryName: String)
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
    /// User clicked "Reinstall" on a stale-hooks card. AppFeature fans
    /// these slots out to `settings.agentHookInstallTapped` so the
    /// existing install machinery runs.
    case reinstallHooksRequested(slots: [AgentHookSlot])
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
    /// User tapped Setup on a Getting Started card. AppFeature routes
    /// each task to the right action (NSOpenPanel, Settings section,
    /// etc.) — the board itself doesn't know about those concerns.
    case gettingStartedSetupRequested(GettingStartedTask)
    /// Something changed (skip set cleared, task count may have shifted)
    /// and the carousel contents need re-computing from live predicates.
    /// AppFeature runs the evaluation and sends back
    /// `.gettingStartedEvaluated`.
    case gettingStartedReevaluateRequested
  }

  @Dependency(TerminalClient.self) var terminalClient
  @Dependency(AutoObserverClient.self) var autoObserverClient
  @Dependency(SessionReferenceScannerClient.self) var scannerClient
  @Dependency(GithubCLIClient.self) var githubCLI
  @Dependency(BackgroundInferenceClient.self) var backgroundInferenceClient
  @Dependency(SupacoolWorktreePruneClient.self) var supacoolWorktreePrune
  @Dependency(RemoteSpawnClient.self) var remoteSpawnClient
  @Dependency(PiSettingsClient.self) var piSettingsClient
  @Dependency(GitClientDependency.self) var gitClient
  @Dependency(\.uuid) var uuid
  @Dependency(\.date) var date

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
        if let bookmarkID = session.sourceBookmarkID {
          state.bookmarkSpawnInFlight.remove(bookmarkID)
        }
        // Surface a short-lived "Starting session" tray card so the user
        // sees the spawn is underway without having to hunt the new card
        // on a crowded board. The card clears on busy=true, when the
        // session is observed live, or via × dismiss. Card id is anchored
        // to `session.id` so lookups are trivial and tests stay
        // deterministic without injecting a `uuid` dependency.
        let creatingCard = TrayCard(
          id: session.id,
          kind: .sessionCreating(sessionID: session.id, displayName: session.displayName)
        )
        state.trayCards.append(creatingCard)
        TranscriptRecorder.shared.append(
          event: .sessionLifecycle(
            kind: "created",
            context: "agent=\(session.agent?.id ?? "shell")",
            at: Date()
          ),
          tabID: TerminalTabID(rawValue: session.id)
        )
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
        // Compute cleanup metadata at trash-time so the eventual
        // permanent-delete (sweep / "Delete now") can fan out
        // verbatim — even after `state.sessions` no longer contains
        // this session and ref-count checks would silently flip.
        let deleteBackingWorktree =
          session.removeBackingWorktreeOnDelete
          && session.worktreeID != session.repositoryID
          && !Self.sessionsUsingWorkspace(
            session.worktreeID, excluding: id, sessions: state.sessions
          )
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
        TranscriptRecorder.shared.append(
          event: .sessionLifecycle(
            kind: "trashed",
            context: deleteBackingWorktree ? "owns-worktree" : "shares-worktree",
            at: Date()
          ),
          tabID: TerminalTabID(rawValue: id)
        )
        let entry = TrashedSession(
          session: session,
          repositoryID: session.repositoryID,
          worktreeID: session.worktreeID,
          deleteBackingWorktree: deleteBackingWorktree,
          additionalWorktreeIDsToDelete: additionalDeletes,
          trashedAt: date.now
        )
        state.$trashedSessions.withLock { trash in
          trash.removeAll { $0.id == id }
          trash.append(entry)
        }
        state.$sessions.withLock { $0.removeAll(where: { $0.id == id }) }
        if state.focusedSessionID == id {
          state.focusedSessionID = nil
        }
        state.trayCards.removeAll { card in
          if case .sessionCreating(let sessionID, _) = card.kind {
            return sessionID == id
          }
          return false
        }
        // Tab destroy still fires; worktree cleanup is deferred to
        // either explicit "Delete now" or the 3-day sweeper.
        return .send(
          .delegate(
            .sessionRemoved(
              sessionID: session.id,
              repositoryID: session.repositoryID,
              worktreeID: session.worktreeID,
              deleteBackingWorktree: false,
              additionalWorktreeIDsToDelete: []
            )
          )
        )

      case .openTrashSheet:
        state.isTrashSheetPresented = true
        return .none

      case .dismissTrashSheet:
        state.isTrashSheetPresented = false
        state.worktreeJanitor = nil
        return .none

      case .restoreFromTrash(let id):
        guard let entry = state.trashedSessions.first(where: { $0.id == id }) else {
          return .none
        }
        state.$trashedSessions.withLock { $0.removeAll { $0.id == id } }
        // Re-insert at the current position (sessions ordering is
        // append-on-create elsewhere; matching that keeps the card
        // appearing at the bottom rather than sneaking back in front).
        state.$sessions.withLock { sessions in
          guard !sessions.contains(where: { $0.id == id }) else { return }
          sessions.append(entry.session)
        }
        TranscriptRecorder.shared.append(
          event: .sessionLifecycle(kind: "restored", context: nil, at: Date()),
          tabID: TerminalTabID(rawValue: id)
        )
        return .none

      case .deleteFromTrash(let id):
        guard let entry = state.trashedSessions.first(where: { $0.id == id }) else {
          return .none
        }
        state.$trashedSessions.withLock { $0.removeAll { $0.id == id } }
        TranscriptRecorder.shared.append(
          event: .sessionLifecycle(kind: "purged", context: nil, at: Date()),
          tabID: TerminalTabID(rawValue: id)
        )
        return .send(
          .delegate(
            .sessionRemoved(
              sessionID: entry.session.id,
              repositoryID: entry.repositoryID,
              worktreeID: entry.worktreeID,
              deleteBackingWorktree: entry.deleteBackingWorktree,
              additionalWorktreeIDsToDelete: entry.additionalWorktreeIDsToDelete
            )
          )
        )

      case .emptyTrash:
        let ids = state.trashedSessions.map(\.id)
        guard !ids.isEmpty else { return .none }
        return .merge(ids.map { .send(.deleteFromTrash(id: $0)) })

      case ._sweepExpiredTrash:
        let now = date.now
        let expiredIDs = state.trashedSessions
          .filter { $0.isExpired(now: now) }
          .map(\.id)
        guard !expiredIDs.isEmpty else { return .none }
        boardLogger.info("Trash sweep: nuking \(expiredIDs.count) expired entries")
        return .merge(expiredIDs.map { .send(.deleteFromTrash(id: $0)) })

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
        // Fast-path auto-dismiss: busy=true means the PTY is live and the
        // agent is actually running.
        if busy {
          state.trayCards.removeAll { card in
            if case .sessionCreating(let sessionID, _) = card.kind {
              return sessionID == id
            }
            return false
          }
        }
        return .none

      case .sessionStatusObserved(let id, let status):
        switch status {
        case .fresh, .inProgress, .waitingOnMe, .awaitingInput:
          state.trayCards.removeAll { card in
            if case .sessionCreating(let sessionID, _) = card.kind {
              return sessionID == id
            }
            return false
          }
        case .detached, .interrupted, .parked, .disconnected:
          break
        }
        return .none

      case .focusSession(let id):
        state.focusedSessionID = id
        return .none

      case .parkSession(let id, let repositories):
        guard let session = state.sessions.first(where: { $0.id == id }) else {
          return .none
        }
        let now = date.now
        state.$sessions.withLock { sessions in
          guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
          sessions[index].parked = true
          sessions[index].lastKnownBusy = false
          sessions[index].lastBusyTransitionAt = nil
          sessions[index].lastActivityAt = now
        }
        TranscriptRecorder.shared.append(
          event: .sessionLifecycle(kind: "parked", context: "detached", at: now),
          tabID: TerminalTabID(rawValue: id)
        )
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

      case .parkActiveSession(let id):
        guard state.sessions.contains(where: { $0.id == id }) else {
          return .none
        }
        let now = date.now
        state.$sessions.withLock { sessions in
          guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
          sessions[index].parked = true
          sessions[index].lastActivityAt = now
        }
        TranscriptRecorder.shared.append(
          event: .sessionLifecycle(kind: "parked", context: "active", at: now),
          tabID: TerminalTabID(rawValue: id)
        )
        if state.focusedSessionID == id {
          state.focusedSessionID = nil
        }
        return .none

      case .unparkSession(let id):
        guard state.sessions.contains(where: { $0.id == id }) else {
          return .none
        }
        let now = date.now
        state.$sessions.withLock { sessions in
          guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
          sessions[index].parked = false
          sessions[index].lastActivityAt = now
        }
        TranscriptRecorder.shared.append(
          event: .sessionLifecycle(kind: "unparked", context: nil, at: now),
          tabID: TerminalTabID(rawValue: id)
        )
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

      case .focusRepository(let repositoryID):
        state.$filters.withLock { $0.selectedRepositoryIDs = [repositoryID] }
        return .none

      case .showAllRepositories:
        state.$filters.withLock { $0.selectedRepositoryIDs = [] }
        return .none

      case .openNewTerminalSheet(let repositories):
        state.newTerminalSheet = NewTerminalFeature.State(
          availableRepositories: IdentifiedArray(uniqueElements: repositories),
          preferredRepositoryID: filteredPreferredRepositoryID(
            in: repositories,
            filters: state.filters
          )
        )
        return .none

      case .openNewTerminalSheetFromSession(let id, let repositories):
        let preferredRepositoryID = state.sessions.first(where: { $0.id == id })?.repositoryID
          ?? filteredPreferredRepositoryID(
            in: repositories,
            filters: state.filters
          )
        state.newTerminalSheet = NewTerminalFeature.State(
          availableRepositories: IdentifiedArray(uniqueElements: repositories),
          preferredRepositoryID: preferredRepositoryID
        )
        return .none

      case .bookmarkTapped(let id, let repositories):
        guard let bookmark = state.bookmarks.first(where: { $0.id == id }) else {
          return .none
        }
        guard !state.unavailableBookmarkIDs.contains(id) else {
          return .none
        }
        guard let repository = repositories.first(where: { $0.id == bookmark.repositoryID }) else {
          boardLogger.warning(
            "bookmarkTapped: no matching repository \(bookmark.repositoryID) in \(repositories.count) repos"
          )
          return .none
        }
        state.bookmarkSpawnInFlight.insert(id)
        let selection: WorkspaceSelection = {
          switch bookmark.worktreeMode {
          case .repoRoot:
            return .repoRoot
          case .newWorktree:
            return .newBranch(name: bookmark.generateWorktreeName(now: date.now))
          }
        }()
        let planMode = bookmark.agent?.supportsPlanMode == true && bookmark.planMode
        let bypassPermissions =
          UserDefaults.standard.object(forKey: "supacool.bypassPermissions") as? Bool ?? true
        @Shared(.settingsFile) var settingsFile
        let fetchOrigin = settingsFile.global.fetchOriginBeforeWorktreeCreation
        let sessionID = uuid()
        let request = SessionSpawner.LocalRequest(
          sessionID: sessionID,
          repository: repository,
          selection: selection,
          agent: bookmark.agent,
          prompt: bookmark.prompt,
          planMode: planMode,
          bypassPermissions: bypassPermissions,
          fetchOriginBeforeCreation: fetchOrigin,
          rerunOwnedWorktreeID: nil,
          pullRequestLookup: .idle,
          suggestedDisplayName: nil,
          removeBackingWorktreeOnDelete: bookmark.worktreeMode == .newWorktree
        )
        let placeholderDisplayName = AgentSession.deriveDisplayName(
          from: bookmark.prompt,
          fallbackID: sessionID
        )
        let placeholder = TrayCard(
          id: sessionID,
          kind: .sessionCreating(sessionID: sessionID, displayName: placeholderDisplayName)
        )
        state.trayCards.append(placeholder)

        let bookmarkID = bookmark.id
        return .run { send in
          do {
            var session = try await SessionSpawner.spawnLocal(request)
            session.sourceBookmarkID = bookmarkID
            await send(._bookmarkSpawnCompleted(session: session))
          } catch {
            await send(
              ._bookmarkSpawnFailed(
                bookmarkID: bookmarkID,
                sessionID: sessionID,
                message: error.localizedDescription
              )
            )
          }
        }

      case .bookmarkEditRequested(let id, let repositories):
        guard let bookmark = state.bookmarks.first(where: { $0.id == id }) else {
          return .none
        }
        let available = IdentifiedArray(uniqueElements: repositories)
        state.newTerminalSheet = NewTerminalFeature.State(
          availableRepositories: available,
          editing: bookmark
        )
        return .none

      case .bookmarkDeleteRequested(let id):
        state.$bookmarks.withLock { $0.removeAll { $0.id == id } }
        return .none

      case ._bookmarkSpawnCompleted(let session):
        if let bookmarkID = session.sourceBookmarkID {
          state.bookmarkSpawnInFlight.remove(bookmarkID)
        }
        if let index = state.trayCards.firstIndex(where: { $0.id == session.id }) {
          state.trayCards[index].kind = .sessionCreating(
            sessionID: session.id,
            displayName: session.displayName
          )
        }
        return .send(.createSession(session))

      case ._bookmarkSpawnFailed(let bookmarkID, let sessionID, let message):
        state.bookmarkSpawnInFlight.remove(bookmarkID)
        state.trayCards.removeAll(where: { $0.id == sessionID })
        boardLogger.warning("Bookmark \(bookmarkID) spawn failed: \(message)")
        return .none

      case .draftTapped(let id, let repositories):
        guard let draft = state.drafts.first(where: { $0.id == id }) else {
          return .none
        }
        let available = IdentifiedArray(uniqueElements: repositories)
        state.newTerminalSheet = NewTerminalFeature.State(
          availableRepositories: available,
          resuming: draft
        )
        return .none

      case .draftDeleteRequested(let id):
        state.$drafts.withLock { $0.removeAll { $0.id == id } }
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
        // probes that dictionary with `session.worktreeID` verbatim. Supacool
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
        TranscriptRecorder.shared.append(
          event: .sessionLifecycle(kind: "resumed", context: "captured-id", at: Date()),
          tabID: TerminalTabID(rawValue: id)
        )
        guard
          let resumeCommand = agent.resumeCommand(
            sessionID: sessionID,
            bypassPermissions: Self.readBypassPermissions()
          )
        else {
          return .send(
            .resumeFailed(id: id, message: "\(agent.displayName) doesn't support resume by id.")
          )
        }
        state.focusedSessionID = id
        let command = resumeCommand + "\r"
        return .run { [terminalClient, piSettingsClient, agent] _ in
          if agent.id == "pi" {
            do {
              try await piSettingsClient.install()
            } catch {
              boardLogger.warning("Failed to auto-install Pi extension: \(error)")
            }
          }
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
        TranscriptRecorder.shared.append(
          event: .sessionLifecycle(kind: "resumed", context: "picker", at: Date()),
          tabID: TerminalTabID(rawValue: id)
        )
        guard
          let pickerCommand =
            agent.resumePickerCommand(bypassPermissions: Self.readBypassPermissions())
        else {
          return .send(
            .resumeFailed(id: id, message: "\(agent.displayName) has no resume picker.")
          )
        }
        state.focusedSessionID = id
        let command = pickerCommand + "\r"
        return .run { [terminalClient, piSettingsClient, agent] _ in
          if agent.id == "pi" {
            do {
              try await piSettingsClient.install()
            } catch {
              boardLogger.warning("Failed to auto-install Pi extension: \(error)")
            }
          }
          await terminalClient.send(
            .createTabWithInput(
              worktree,
              input: command,
              runSetupScriptIfNew: false,
              id: id
            )
          )
        }

      case .restoreShellSessionLayout(let id, let repositories):
        guard let session = state.sessions.first(where: { $0.id == id }) else {
          return .none
        }
        guard session.agent == nil, !session.isRemote else {
          return .send(
            .resumeFailed(id: id, message: "Only local shell sessions can restore a shell layout.")
          )
        }
        guard let repository = repositories.first(where: { $0.id == session.repositoryID }) else {
          return .send(.resumeFailed(id: id, message: "Repository no longer registered."))
        }
        let now = date.now
        state.$sessions.withLock { sessions in
          guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
          sessions[index].lastKnownBusy = false
          sessions[index].lastBusyTransitionAt = nil
          sessions[index].lastActivityAt = now
          sessions[index].parked = false
        }
        state.focusedSessionID = id
        TranscriptRecorder.shared.append(
          event: .sessionLifecycle(kind: "restored-shell-layout", context: nil, at: now),
          tabID: TerminalTabID(rawValue: id)
        )
        let worktree = Self.shellRestoreWorktree(for: session, repository: repository)
        return .run { _ in
          await terminalClient.send(
            .restoreShellLayout(worktree, tabID: TerminalTabID(rawValue: id))
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
            let baseDirectory = SupacoolPaths.worktreeBaseDirectory(
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
          let response = await autoObserverClient.decide(screen, userInstructions, tabID)
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
        var sessionToCreate = session
        // Preserve lineage across rerun so coupled cards/bookmarks stay
        // linked for the replacement incarnation too.
        if let pendingID = state.pendingRerunSessionID,
          let previous = state.sessions.first(where: { $0.id == pendingID })
        {
          if sessionToCreate.sourceBookmarkID == nil {
            sessionToCreate.sourceBookmarkID = previous.sourceBookmarkID
          }
          if sessionToCreate.debugSourceSessionID == nil {
            sessionToCreate.debugSourceSessionID = previous.debugSourceSessionID
          }
        }
        // The rerun's replacement is ready — drop the original now.
        if let pendingID = state.pendingRerunSessionID {
          state.$sessions.withLock { $0.removeAll(where: { $0.id == pendingID }) }
          state.pendingRerunSessionID = nil
        }
        return .send(.createSession(sessionToCreate))

      case .newTerminalSheet(.presented(.delegate(.spawnRequested(let request, let displayName)))):
        // Local-path submit: dismiss the sheet immediately so the user
        // doesn't sit through worktree creation. A placeholder tray
        // card stands in until the real session card is created — its
        // ID is anchored to the pre-allocated session UUID, so when
        // `.createSession` runs, `IdentifiedArrayOf.append` no-ops on
        // the duplicate ID and the same card transitions seamlessly
        // into the post-spawn lifecycle.
        state.newTerminalSheet = nil
        let placeholder = TrayCard(
          id: request.sessionID,
          kind: .sessionCreating(sessionID: request.sessionID, displayName: displayName)
        )
        state.trayCards.append(placeholder)
        return .run { send in
          do {
            let session = try await SessionSpawner.spawnLocal(request)
            await send(._sessionSpawnCompleted(session: session))
          } catch let conflict as NewTerminalError {
            if case .branchAlreadyCheckedOut(let branch, let existing) = conflict {
              await send(
                ._sessionSpawnConflict(
                  sessionID: request.sessionID,
                  placeholderDisplayName: displayName,
                  request: request,
                  branch: branch,
                  existing: existing
                )
              )
            } else {
              await send(
                ._sessionSpawnFailed(
                  sessionID: request.sessionID,
                  message: conflict.localizedDescription
                )
              )
            }
          } catch {
            await send(
              ._sessionSpawnFailed(
                sessionID: request.sessionID,
                message: error.localizedDescription
              )
            )
          }
        }

      case ._sessionSpawnCompleted(let session):
        var sessionToCreate = session
        // Preserve lineage across rerun so coupled cards/bookmarks stay
        // linked for the replacement incarnation too.
        if let pendingID = state.pendingRerunSessionID,
          let previous = state.sessions.first(where: { $0.id == pendingID })
        {
          if sessionToCreate.sourceBookmarkID == nil {
            sessionToCreate.sourceBookmarkID = previous.sourceBookmarkID
          }
          if sessionToCreate.debugSourceSessionID == nil {
            sessionToCreate.debugSourceSessionID = previous.debugSourceSessionID
          }
        }
        // Refresh the placeholder's displayName in case it was refined
        // (e.g. PR-context displayName is set on the AgentSession).
        if let index = state.trayCards.firstIndex(where: { $0.id == sessionToCreate.id }) {
          state.trayCards[index].kind = .sessionCreating(
            sessionID: sessionToCreate.id,
            displayName: sessionToCreate.displayName
          )
        }
        if let pendingID = state.pendingRerunSessionID {
          state.$sessions.withLock { $0.removeAll(where: { $0.id == pendingID }) }
          state.pendingRerunSessionID = nil
        }
        return .send(.createSession(sessionToCreate))

      case ._sessionSpawnFailed(let sessionID, let message):
        boardLogger.warning("Local session \(sessionID) spawn failed: \(message)")
        // Drop the placeholder; v1 has no error tray-card variant.
        state.trayCards.removeAll(where: { $0.id == sessionID })
        // Keep `pendingRerunSessionID` set so the user's original
        // session card stays put — they can retry.
        return .none

      case let ._sessionSpawnConflict(sessionID, placeholderDisplayName, request, branch, existing):
        boardLogger.info(
          "Branch '\(branch)' for session \(sessionID) is already checked out at "
            + "\(existing.workingDirectory.path(percentEncoded: false))"
        )
        state.worktreeConflictAlert = WorktreeConflictAlertState(
          id: uuid(),
          sessionID: sessionID,
          placeholderDisplayName: placeholderDisplayName,
          request: request,
          branch: branch,
          existingWorktree: existing
        )
        // Placeholder tray card stays up — same `sessionCreating` kind
        // anchored on `request.sessionID` — so when the user picks Reuse
        // or Delete & recreate the retry slots into the same UI without
        // flicker.
        return .none

      case .worktreeConflictReuseTapped:
        guard let alert = state.worktreeConflictAlert else { return .none }
        state.worktreeConflictAlert = nil
        let request = alert.request
        let existing = alert.existingWorktree
        return .run { send in
          do {
            let session = try await SessionSpawner.spawnLocalAdopting(
              request: request,
              existingWorktree: existing
            )
            await send(._sessionSpawnCompleted(session: session))
          } catch {
            await send(
              ._sessionSpawnFailed(
                sessionID: request.sessionID,
                message: error.localizedDescription
              )
            )
          }
        }

      case .worktreeConflictDeleteAndRecreateTapped:
        guard let alert = state.worktreeConflictAlert else { return .none }
        state.worktreeConflictAlert = nil
        let request = alert.request
        let existing = alert.existingWorktree
        return .run { [gitClient] send in
          do {
            // `deleteBranch: false` — we're only removing the worktree
            // checkout, not the branch ref. The whole point of the
            // delete-and-recreate path is keeping the branch around.
            _ = try await gitClient.removeWorktree(existing, false)
            let session = try await SessionSpawner.spawnLocal(request)
            await send(._sessionSpawnCompleted(session: session))
          } catch {
            await send(
              ._sessionSpawnFailed(
                sessionID: request.sessionID,
                message: error.localizedDescription
              )
            )
          }
        }

      case .dismissWorktreeConflictAlert:
        guard let alert = state.worktreeConflictAlert else { return .none }
        state.worktreeConflictAlert = nil
        // Drop the placeholder — user opted out of recovery.
        state.trayCards.removeAll(where: { $0.id == alert.sessionID })
        // Keep pendingRerunSessionID intact so the original session
        // card stays put.
        return .none

      case .newTerminalSheet(.presented(.delegate(.bookmarkSaved(let bookmark)))):
        // Fires BEFORE `.created` in the sheet's `.sessionReady`
        // ordering, so the bookmark pill is in state the moment the
        // session card appears.
        state.$bookmarks.withLock { bookmarks in
          if let index = bookmarks.firstIndex(where: { $0.id == bookmark.id }) {
            bookmarks[index] = bookmark
          } else {
            bookmarks.append(bookmark)
          }
        }
        return .none

      case .newTerminalSheet(.presented(.delegate(.draftSaved(let draft)))):
        // Upsert by id: reopened drafts preserve their id so a second
        // Save Draft replaces in place rather than fanning out duplicates.
        state.$drafts.withLock { drafts in
          if let index = drafts.firstIndex(where: { $0.id == draft.id }) {
            drafts[index] = draft
          } else {
            drafts.append(draft)
          }
        }
        // Sheet stays open after a normal save? No — Save Draft is the
        // user signalling "park this and get out of the way." Mirror
        // the Cancel path: dismiss the sheet.
        state.newTerminalSheet = nil
        state.pendingRerunSessionID = nil
        return .none

      case .newTerminalSheet(.presented(.delegate(.draftConsumed(let id)))):
        // Launching a draft "uses it up." Fires before `.created` /
        // `.spawnRequested` so the pill disappears from the board the
        // moment the new session card materializes.
        state.$drafts.withLock { $0.removeAll { $0.id == id } }
        return .none

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
        case .hookInstallFailed:
          state.trayCards.remove(id: id)
          return .send(.delegate(.openSettingsRequested(section: .codingAgents)))
        case .worktreeDeleteFailed:
          state.trayCards.remove(id: id)
          return .none
        }

      case .trayCardSecondaryTapped(let id):
        guard let card = state.trayCards[id: id] else { return .none }
        switch card.kind {
        case .staleHooks(let slots):
          // Optimistic: drop the card immediately so the user sees a
          // response. If any slot install fails, AppFeature will push a
          // `.hookInstallFailed` card describing the failure.
          state.trayCards.remove(id: id)
          return .send(.delegate(.reinstallHooksRequested(slots: slots)))
        case .sessionCreating, .hookInstallFailed, .worktreeDeleteFailed:
          return .none
        }

      case .trayNoteHookInstalled(let slot):
        // Narrow any stale-hooks cards that include this slot. If the
        // card's slot list becomes empty, the card is removed entirely.
        // Also clears any matching `hookInstallFailed` card for this slot
        // so a success after a prior failure reads as resolution.
        for card in state.trayCards {
          switch card.kind {
          case .staleHooks(let slots) where slots.contains(slot):
            let remaining = slots.filter { $0 != slot }
            if remaining.isEmpty {
              state.trayCards.remove(id: card.id)
            } else {
              state.trayCards[id: card.id]?.kind = .staleHooks(slots: remaining)
            }
          case .hookInstallFailed(let failedSlot, _) where failedSlot == slot:
            state.trayCards.remove(id: card.id)
          default:
            break
          }
        }
        return .none

      case .gettingStartedEvaluated(let pending):
        state.gettingStarted.tasks = pending
        if pending.isEmpty {
          state.gettingStarted.isPresented = false
          state.gettingStarted.currentIndex = 0
        } else {
          // Keep the user's current page when possible — if the current
          // task was just completed/skipped, clamp to the nearest valid
          // index so the view doesn't jump to the start on every
          // re-evaluation.
          state.gettingStarted.currentIndex = min(
            state.gettingStarted.currentIndex,
            max(pending.count - 1, 0)
          )
          // Present on first evaluation that finds work. We gate on the
          // persisted skip set rather than a session flag so a brand-new
          // launch with no skips auto-opens, but a relaunch after
          // skipping all three only surfaces the panel if the user hits
          // "Show Again".
          state.gettingStarted.isPresented = true
        }
        return .none

      case .gettingStartedSetCurrentIndex(let index):
        guard !state.gettingStarted.tasks.isEmpty else { return .none }
        state.gettingStarted.currentIndex = max(
          0, min(index, state.gettingStarted.tasks.count - 1)
        )
        return .none

      case .gettingStartedSetupTapped(let task):
        return .send(.delegate(.gettingStartedSetupRequested(task)))

      case .gettingStartedSkipTapped(let task):
        state.$skippedGettingStartedTasks.withLock { raw in
          if !raw.contains(task.rawValue) {
            raw.append(task.rawValue)
          }
        }
        var remaining = state.gettingStarted.tasks
        remaining.removeAll { $0 == task }
        state.gettingStarted.tasks = remaining
        if remaining.isEmpty {
          state.gettingStarted.isPresented = false
          state.gettingStarted.currentIndex = 0
        } else {
          state.gettingStarted.currentIndex = min(
            state.gettingStarted.currentIndex,
            remaining.count - 1
          )
        }
        return .none

      case .gettingStartedDismiss:
        state.gettingStarted.isPresented = false
        return .none

      case .gettingStartedShowAgain:
        state.$skippedGettingStartedTasks.withLock { $0.removeAll() }
        return .send(.delegate(.gettingStartedReevaluateRequested))

      case .openWorktreeJanitor(let repositoryID, let repositoryName):
        if let current = state.worktreeJanitor,
          current.repositoryID != repositoryID
        {
          state.worktreeJanitor = nil
          return .send(
            ._presentWorktreeJanitor(
              repositoryID: repositoryID,
              repositoryName: repositoryName
            )
          )
        }
        if state.worktreeJanitor?.repositoryID == repositoryID {
          return .none
        }
        state.worktreeJanitor = WorktreeJanitorFeature.State(
          repositoryID: repositoryID,
          repositoryName: repositoryName,
          sessionsSnapshot: state.sessions
        )
        return .none

      case ._presentWorktreeJanitor(let repositoryID, let repositoryName):
        state.worktreeJanitor = WorktreeJanitorFeature.State(
          repositoryID: repositoryID,
          repositoryName: repositoryName,
          sessionsSnapshot: state.sessions
        )
        return .none

      case .worktreeJanitor(.presented(.delegate(.dismissed))):
        state.worktreeJanitor = nil
        return .none

      case .worktreeJanitor(.presented(.delegate(.removeOrphanSessionCardsRequested(let ids)))):
        // Chain .removeSession per orphan id — same path
        // .confirmPruneOrphans used to take, so tab cleanup and the
        // sessionRemoved delegate all flow through the existing
        // machinery without reimplementing it here.
        return .run { send in
          for id in ids {
            await send(.removeSession(id: id))
          }
        }

      case .worktreeJanitor:
        return .none

      case .delegate:
        return .none

      case .newTerminalSheet:
        return .none

      case .debugSessionRequested(let id, let repositories):
        guard let session = state.sessions.first(where: { $0.id == id }) else {
          return .none
        }
        // Two structurally different sheet states. When supacool isn't
        // registered the sheet drops the editor and Spawn button and
        // shows a "register supacool first" panel — there's no useful
        // text to capture before the agent has somewhere to run.
        var sheetState = DebugSessionFeature.State(sourceSession: session)
        sheetState.isSupacoolRepoRegistered =
          SupacoolDebugSupport.findSupacoolRepository(in: repositories) != nil
        // Stash repositories so the spawn handler can re-run the lookup
        // at submit time; cleared on close.
        state.pendingDebugRepositories = repositories
        state.debugSheet = sheetState
        return .none

      case .debugSheet(.presented(.delegate(.spawnRequested(let observation, let agent, let source)))):
        let repositories = state.pendingDebugRepositories
        guard let supacoolRepo = SupacoolDebugSupport.findSupacoolRepository(in: repositories) else {
          // Race-guard: user dismissed the picker without registering,
          // then hit Spawn. Re-flip the sheet to the missing-repo mode.
          state.debugSheet?.isSupacoolRepoRegistered = false
          return .none
        }
        state.debugSheet = nil
        state.pendingDebugRepositories = []

        let tracePath = TranscriptRecorder.shared.transcriptURL(
          tabID: TerminalTabID(rawValue: source.id)
        )?.path(percentEncoded: false) ?? "(trace file not yet written)"
        let prompt = SupacoolDebugSupport.buildDebugPrompt(
          observation: observation,
          sourceSession: source,
          tracePath: tracePath
        )
        let worktreeName = SupacoolDebugSupport.debugWorktreeName(
          sourceDisplayName: source.displayName
        )
        let bypass =
          UserDefaults.standard.object(forKey: "supacool.bypassPermissions") as? Bool ?? true
        @Shared(.settingsFile) var settingsFile
        let fetchOrigin = settingsFile.global.fetchOriginBeforeWorktreeCreation
        let request = SessionSpawner.LocalRequest(
          sessionID: uuid(),
          repository: supacoolRepo,
          selection: .newBranch(name: worktreeName),
          agent: agent,
          prompt: prompt,
          planMode: false,
          bypassPermissions: bypass,
          fetchOriginBeforeCreation: fetchOrigin,
          rerunOwnedWorktreeID: nil,
          pullRequestLookup: .idle,
          suggestedDisplayName: SupacoolDebugSupport.debugDisplayName(
            sourceDisplayName: source.displayName
          ),
          removeBackingWorktreeOnDelete: true
        )
        return .run { send in
          do {
            var session = try await SessionSpawner.spawnLocal(request)
            session.debugSourceSessionID = source.id
            await send(._debugSpawnCompleted(session: session))
          } catch {
            await send(._debugSpawnFailed(message: error.localizedDescription))
          }
        }

      case .debugSheet(.presented(.delegate(.cancelled))):
        state.debugSheet = nil
        state.pendingDebugRepositories = []
        return .none

      case .debugSheet(.presented(.delegate(.registerSupacoolRequested))):
        // Close the sheet and reuse the same path the Getting Started
        // "Set up your first repo" task uses — AppFeature catches this
        // delegate and triggers the macOS folder picker. The user can
        // re-open Debug session… afterward.
        state.debugSheet = nil
        state.pendingDebugRepositories = []
        return .send(.delegate(.gettingStartedSetupRequested(.setupRepo)))

      case .debugSheet:
        return .none

      case ._debugSpawnCompleted(let session):
        return .send(.createSession(session))

      case ._debugSpawnFailed(let message):
        boardLogger.warning("Debug session spawn failed: \(message)")
        return .none
      }
    }
    .ifLet(\.$newTerminalSheet, action: \.newTerminalSheet) {
      NewTerminalFeature()
    }
    .ifLet(\.$debugSheet, action: \.debugSheet) {
      DebugSessionFeature()
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
    if let resumeID = session.agentNativeSessionID, !resumeID.isEmpty,
      let resumeCommand = agent.resumeCommand(sessionID: resumeID, bypassPermissions: bypass)
    {
      return resumeCommand
    }
    return agent.command(prompt: session.initialPrompt, bypassPermissions: bypass)
  }

  fileprivate static func shellRestoreWorktree(
    for session: AgentSession,
    repository: Repository
  ) -> Worktree {
    let workingDirectory = URL(fileURLWithPath: session.currentWorkspacePath).standardizedFileURL
    return Worktree(
      id: session.worktreeID,
      name: workingDirectory.lastPathComponent,
      detail: "",
      workingDirectory: workingDirectory,
      repositoryRootURL: repository.rootURL.standardizedFileURL
    )
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
    let trace = InferenceTraceContext(
      tabID: TerminalTabID(rawValue: sessionID),
      purpose: "session-title"
    )
    return .run { [backgroundInferenceClient] send in
      do {
        let raw = try await backgroundInferenceClient.infer(inferencePrompt, trace)
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

/// When the toolbar filter is narrowed to exactly one repo, prefer that
/// repo as the New Terminal sheet's default selection. Returns nil for
/// "All" or multi-selected filters so the sheet falls back to its usual
/// `availableRepositories.first` default.
private func filteredPreferredRepositoryID(
  in repositories: [Repository],
  filters: BoardFilters
) -> Repository.ID? {
  guard !filters.showsAllRepositories else { return nil }
  let selected = repositories.filter { filters.selectedRepositoryIDs.contains($0.id) }
  guard selected.count == 1 else { return nil }
  return selected.first?.id
}

// MARK: - Derived queries

extension BoardFeature.State {
  /// Sessions visible under the current repo filter, preserving insertion order.
  var visibleSessions: [AgentSession] {
    sessions.filter { filters.includes(repositoryID: $0.repositoryID) }
  }

  /// Bookmark ids that should not be launchable right now:
  /// - a spawn is already in-flight for that bookmark
  /// - a live session spawned from that bookmark still exists
  var unavailableBookmarkIDs: Set<Bookmark.ID> {
    let activeSessionBookmarkIDs = sessions.compactMap(\.sourceBookmarkID)
    return bookmarkSpawnInFlight.union(activeSessionBookmarkIDs)
  }

  /// Look up a session by ID (O(n), fine for small N).
  func session(id: AgentSession.ID?) -> AgentSession? {
    guard let id else { return nil }
    return sessions.first(where: { $0.id == id })
  }
}

// Real `NewTerminalFeature` lives in
// Supacool/Features/Board/Reducer/NewTerminalFeature.swift
