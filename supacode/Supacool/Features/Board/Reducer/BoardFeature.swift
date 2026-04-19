import ComposableArchitecture
import Foundation

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

    /// When non-nil, the root view shows this session's terminal full-screen
    /// instead of the board. Not persisted — fresh launches always land on
    /// the board.
    var focusedSessionID: AgentSession.ID?

    /// The new-terminal sheet state, if open.
    @Presents var newTerminalSheet: NewTerminalFeature.State?

    /// Sessions whose Auto-Observer is currently reading/deciding.
    /// Guards against re-entrant triggers on the same session.
    var autoObserverInFlight: Set<AgentSession.ID> = []
  }

  enum Action: BindableAction, Equatable {
    case binding(BindingAction<State>)

    // MARK: Session CRUD
    case createSession(AgentSession)
    case renameSession(id: AgentSession.ID, newName: String)
    case removeSession(id: AgentSession.ID)
    case markSessionActivity(id: AgentSession.ID)
    case markSessionCompletedOnce(id: AgentSession.ID)
    case updateSessionBusyState(id: AgentSession.ID, busy: Bool)
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
    case rerunDetachedSession(id: AgentSession.ID, repositories: [Repository])
    case resumeDetachedSession(id: AgentSession.ID, repositories: [Repository])
    /// Fallback resume path: no captured id, so we launch the agent's own
    /// built-in resume picker scoped to the session's working directory.
    case resumeDetachedSessionWithPicker(id: AgentSession.ID, repositories: [Repository])
    case resumeFailed(id: AgentSession.ID, message: String)
    case newTerminalSheet(PresentationAction<NewTerminalFeature.Action>)

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

    case delegate(Delegate)
  }

  enum Delegate: Equatable {
    case sessionRemoved(
      sessionID: AgentSession.ID,
      repositoryID: Repository.ID,
      worktreeID: Worktree.ID,
      deleteBackingWorktree: Bool
    )
  }

  @Dependency(TerminalClient.self) var terminalClient
  @Dependency(AutoObserverClient.self) var autoObserverClient
  @Dependency(SessionReferenceScannerClient.self) var scannerClient
  @Dependency(GithubCLIClient.self) var githubCLI

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
        // Intentionally do NOT focus the new session. Spawning an agent
        // is background work; the user stays on the board and sees the
        // new card appear in "In Progress." They can tap in when ready.
        return .none

      case .renameSession(let id, let newName):
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }
        state.$sessions.withLock { sessions in
          guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
          sessions[index].displayName = trimmed
        }
        return .none

      case .removeSession(let id):
        guard let session = state.sessions.first(where: { $0.id == id }) else {
          return .none
        }
        let deleteBackingWorktree =
          session.removeBackingWorktreeOnDelete
          && session.worktreeID != session.repositoryID
          && !state.sessions.contains(where: { $0.id != id && $0.worktreeID == session.worktreeID })
        state.$sessions.withLock { $0.removeAll(where: { $0.id == id }) }
        if state.focusedSessionID == id {
          state.focusedSessionID = nil
        }
        return .send(
          .delegate(
            .sessionRemoved(
              sessionID: session.id,
              repositoryID: session.repositoryID,
              worktreeID: session.worktreeID,
              deleteBackingWorktree: deleteBackingWorktree
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

      case .updateSessionBusyState(let id, let busy):
        state.$sessions.withLock { sessions in
          guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
          guard sessions[index].lastKnownBusy != busy else { return }
          sessions[index].lastKnownBusy = busy
          sessions[index].lastBusyTransitionAt = Date()
          sessions[index].lastActivityAt = Date()
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

      case .rerunDetachedSession(let id, let repositories):
        guard let previous = state.sessions.first(where: { $0.id == id }) else {
          return .none
        }
        // Drop the detached card and pop focus so the user lands on the
        // sheet with the board behind it.
        state.$sessions.withLock { $0.removeAll(where: { $0.id == id }) }
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
        return .send(.createSession(session))

      case .newTerminalSheet(.presented(.delegate(.cancel))):
        state.newTerminalSheet = nil
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

      case .delegate:
        return .none

      case .newTerminalSheet:
        return .none
      }
    }
    .ifLet(\.$newTerminalSheet, action: \.newTerminalSheet) {
      NewTerminalFeature()
    }
  }

  /// Build the `Worktree` value handed to `TerminalClient` when resuming. The
  /// returned `worktree.id` is pinned to `session.worktreeID` verbatim so the
  /// new tab lands under the same key the detached view probes for.
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
