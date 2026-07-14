import ComposableArchitecture
import Foundation
import IdentifiedCollections

private nonisolated let boardLogger = SupaLogger("Board")

/// The session-lifecycle reducer handlers — create, park, resume/reconnect,
/// convert-to-worktree, rerun, and spawn completion/failure — plus the
/// remote/worktree resume helpers, mechanically extracted from
/// `BoardFeature.swift`; behavior identical.
extension BoardFeature {
  func reduceCreateSession(state: inout State, session: AgentSession) -> Effect<Action> {
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
        context: Self.lifecycleCreatedContext(for: session),
        at: Date()
      ),
      tabID: TerminalTabID(rawValue: session.id)
    )
    // Intentionally do NOT focus the new session. Spawning an agent
    // is background work; the user stays on the board and sees the
    // new card appear in "In Progress." They can tap in when ready.
    return autoDisplayNameEffect(for: session)
  }

  func reduceParkSession(state: inout State, id: AgentSession.ID, repositories: [Repository]) -> Effect<Action> {
    guard let session = state.sessions.first(where: { $0.id == id }) else {
      return .none
    }
    let now = date.now
    state.$sessions.withLock { sessions in
      guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
      sessions[index].parked = true
      sessions[index].parkedActive = false
      sessions[index].updatePrimaryTerminal {
        $0.lastKnownBusy = false
        $0.lastBusyTransitionAt = nil
        $0.lastActivityAt = now
      }
    }
    state.reinitializingSessionIDs.remove(id)
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
    let shouldReleaseOwnedProcesses = Self.allSessionsParked(
      inWorkspace: session.currentWorkspacePath,
      sessions: state.sessions
    )
    let releasePath = session.currentWorkspacePath
    let lifecycleEffect = prepareAutoStopLifecycleEffect(
      &state,
      session: session,
      reason: .park,
      sessions: state.sessions
    )
    let terminalEffect: Effect<Action> = .run { _ in
      await terminalClient.send(
        .destroyTab(worktree, tabID: TerminalTabID(rawValue: id))
      )
      if shouldReleaseOwnedProcesses {
        await terminalClient.send(.releaseOwnedProcesses(worktreePath: releasePath))
      }
    }
    return .merge(lifecycleEffect, terminalEffect)
  }

  func reduceParkActiveSession(state: inout State, id: AgentSession.ID) -> Effect<Action> {
    guard let session = state.sessions.first(where: { $0.id == id }) else {
      return .none
    }
    let now = date.now
    state.$sessions.withLock { sessions in
      guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
      sessions[index].parked = true
      sessions[index].parkedActive = true
      sessions[index].updatePrimaryTerminal { $0.lastActivityAt = now }
    }
    state.reinitializingSessionIDs.remove(id)
    TranscriptRecorder.shared.append(
      event: .sessionLifecycle(kind: "parked", context: "active", at: now),
      tabID: TerminalTabID(rawValue: id)
    )
    if state.focusedSessionID == id {
      state.focusedSessionID = nil
    }
    guard Self.allSessionsParked(
      inWorkspace: session.currentWorkspacePath,
      sessions: state.sessions
    ) else {
      return .none
    }
    let releasePath = session.currentWorkspacePath
    let lifecycleEffect = prepareAutoStopLifecycleEffect(
      &state,
      session: session,
      reason: .park,
      sessions: state.sessions
    )
    let releaseEffect: Effect<Action> = .run { _ in
      await terminalClient.send(.releaseOwnedProcesses(worktreePath: releasePath))
    }
    return .merge(lifecycleEffect, releaseEffect)
  }

  func reduceResumeDetachedSession(
    state: inout State,
    id: AgentSession.ID,
    repositories: [Repository],
    focusOnComplete: Bool
  ) -> Effect<Action> {
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
      sessions[index].parked = false
      sessions[index].parkedActive = false
      sessions[index].updatePrimaryTerminal {
        $0.lastKnownBusy = false
        $0.lastBusyTransitionAt = nil
        $0.lastActivityAt = Date()
      }
    }
    state.reinitializingSessionIDs.insert(id)
    TranscriptRecorder.shared.append(
      event: .sessionLifecycle(kind: "resumed", context: "captured-id", at: Date()),
      tabID: TerminalTabID(rawValue: id)
    )
    guard
      let resumeCommand = agent.resumeCommand(
        sessionID: sessionID,
        bypassPermissions: Self.readBypassPermissions(),
        model: session.model
      )
    else {
      return .send(
        .resumeFailed(id: id, message: "\(agent.displayName) doesn't support resume by id.")
      )
    }
    if focusOnComplete {
      state.focusedSessionID = id
    }
    let command = resumeCommand + "\r"
    let repoRoot = repository.rootURL
    let ownsWorktree = Self.ownsWorktree(session)
    return .run { [terminalClient, piSettingsClient, gitClient, agent] send in
      // A restored session's worktree may have been deleted on trash. Rebuild
      // it before resuming — `--resume` is cwd-scoped, so resuming from a
      // fallback directory can't find the conversation.
      if let failure = await Self.recreateWorktreeIfMissing(
        worktree: worktree,
        ownsWorktree: ownsWorktree,
        repoRoot: repoRoot,
        gitClient: gitClient
      ) {
        await send(.resumeFailed(id: id, message: failure))
        return
      }
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
  }

  func reduceResumeDetachedSessionWithPicker(
    state: inout State,
    id: AgentSession.ID,
    repositories: [Repository]
  ) -> Effect<Action> {
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
      sessions[index].parked = false
      sessions[index].parkedActive = false
      sessions[index].updatePrimaryTerminal {
        $0.lastKnownBusy = false
        $0.lastBusyTransitionAt = nil
        $0.lastActivityAt = Date()
      }
    }
    state.reinitializingSessionIDs.insert(id)
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
    let repoRoot = repository.rootURL
    let ownsWorktree = Self.ownsWorktree(session)
    return .run { [terminalClient, piSettingsClient, gitClient, agent] send in
      // Same cwd sensitivity as the captured-id path: the resume picker only
      // lists conversations belonging to the current directory's project, so a
      // missing worktree would show an empty (or wrong) picker.
      if let failure = await Self.recreateWorktreeIfMissing(
        worktree: worktree,
        ownsWorktree: ownsWorktree,
        repoRoot: repoRoot,
        gitClient: gitClient
      ) {
        await send(.resumeFailed(id: id, message: failure))
        return
      }
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
  }

  func reduceRestoreShellSessionLayout(
    state: inout State,
    id: AgentSession.ID,
    repositories: [Repository]
  ) -> Effect<Action> {
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
      sessions[index].parked = false
      sessions[index].parkedActive = false
      sessions[index].updatePrimaryTerminal {
        $0.lastKnownBusy = false
        $0.lastBusyTransitionAt = nil
        $0.lastActivityAt = now
      }
    }
    state.reinitializingSessionIDs.insert(id)
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
  }

  func reduceReconnectRemoteSession(state: inout State, id: AgentSession.ID) -> Effect<Action> {
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
      sessions[index].updatePrimaryTerminal {
        $0.lastKnownBusy = false
        $0.lastBusyTransitionAt = nil
        $0.lastActivityAt = Date()
      }
    }
    state.reinitializingSessionIDs.insert(id)
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
      await terminalClient.send(
        .createRemoteTab(worktree, command: sshCommand, id: id, surfaceID: id)
      )
    }
  }

  func reduceConvertSessionToWorktree(
    state: inout State,
    id: AgentSession.ID,
    branchName: String,
    repositories: [Repository]
  ) -> Effect<Action> {
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
  }

  func reduceRerunDetachedSession(
    state: inout State,
    id: AgentSession.ID,
    repositories: [Repository]
  ) -> Effect<Action> {
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
  }

  func reduceSessionSpawnCompleted(state: inout State, session: AgentSession) -> Effect<Action> {
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
  }

  func reduceSessionSpawnFailed(
    state: inout State,
    sessionID: AgentSession.ID,
    message: String,
    draftSnapshot: Draft?
  ) -> Effect<Action> {
    boardLogger.warning("Local session \(sessionID) spawn failed: \(message)")
    // Convert the in-flight placeholder card into a red failure
    // card so the user sees what went wrong instead of watching
    // the "Starting session" toast disappear silently. Falls back
    // to appending a fresh card if the placeholder was already
    // dropped (e.g. user dismissed it manually mid-spawn).
    //
    // `draftSnapshot` (when non-nil) lets the user tap the failed
    // card to reopen the New Terminal sheet with their original
    // values — see `trayCardPrimaryTapped`.
    let displayName: String
    if let index = state.trayCards.firstIndex(where: { $0.id == sessionID }),
      case .sessionCreating(_, let placeholderName) = state.trayCards[index].kind
    {
      displayName = placeholderName
      state.trayCards[index].kind = .sessionSpawnFailed(
        displayName: displayName,
        message: message,
        draftSnapshot: draftSnapshot
      )
    } else {
      displayName = "Session"
      state.trayCards.append(
        TrayCard(
          id: sessionID,
          kind: .sessionSpawnFailed(
            displayName: displayName,
            message: message,
            draftSnapshot: draftSnapshot
          )
        )
      )
    }
    // Keep `pendingRerunSessionID` set so the user's original
    // session card stays put — they can retry.
    return .none
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
      let resumeCommand = agent.resumeCommand(
        sessionID: resumeID,
        bypassPermissions: bypass,
        model: session.model
      )
    {
      return resumeCommand
    }
    return agent.command(
      prompt: session.initialPrompt,
      bypassPermissions: bypass,
      model: session.model
    )
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

  /// True when every session whose `currentWorkspacePath` matches the
  /// given path is parked. Empty match (no sessions found) returns
  /// false so we don't fire `releaseOwnedProcesses` for a worktree we
  /// don't actually own.
  fileprivate static func allSessionsParked(
    inWorkspace path: String,
    sessions: [AgentSession]
  ) -> Bool {
    let matching = sessions.filter { $0.currentWorkspacePath == path }
    guard !matching.isEmpty else { return false }
    return matching.allSatisfy(\.parked)
  }

  /// One auxiliary terminal that needs its tab re-spawned at launch.
  struct AuxiliaryReattachJob: Sendable, Equatable {
    let worktree: Worktree
    let tabID: UUID
  }

  /// Walk all sessions and emit a reattach job for every auxiliary
  /// terminal whose owning repository is registered. The agent (primary)
  /// terminal is skipped so an `.interrupted` card stays distinguishable
  /// — the user reanimates via Resume/Rerun explicitly. Remote sessions
  /// are skipped: their tabs are tied to live ssh and tmux state that
  /// the reattach path doesn't understand. Repositories that aren't
  /// registered any more (e.g. user removed a repo between quits) are
  /// silently skipped — the corresponding session is already
  /// `.disconnected` / `.detached` in the UI.
  static func collectAuxiliaryReattachJobs(
    sessions: [AgentSession],
    repositories: [Repository]
  ) -> [AuxiliaryReattachJob] {
    var jobs: [AuxiliaryReattachJob] = []
    for session in sessions where !session.isRemote {
      guard !session.auxiliaryTerminals.isEmpty else { continue }
      guard let repository = repositories.first(where: { $0.id == session.repositoryID })
      else { continue }
      let worktree = Self.resumeWorktree(for: session, repository: repository)
      for terminal in session.auxiliaryTerminals {
        jobs.append(AuxiliaryReattachJob(worktree: worktree, tabID: terminal.id))
      }
    }
    return jobs
  }

  /// Rebuilds the session's worktree directory when it has gone missing.
  ///
  /// Trashing a worktree-owning session `git worktree remove`s its directory
  /// immediately — the trash entry keeps only session metadata — so a session
  /// that is later restored can point at a path that no longer exists. That
  /// matters because `<agent> --resume <id>` is scoped to the *current
  /// directory's* project (Claude looks for the conversation under
  /// `~/.claude/projects/<hashed-cwd>/<id>.jsonl`). Resuming in a shell that
  /// fell back to some other worktree makes the agent search the wrong project
  /// and report the cryptic "No conversation found with session ID".
  ///
  /// The conversation history itself survives the worktree removal — it's keyed
  /// by the original path, not stored in the worktree — so recreating the
  /// worktree at that exact path makes resume resolve again with zero loss.
  ///
  /// Returns `nil` when the directory is present (or was rebuilt), or a
  /// user-facing message when it's gone and can't be rebuilt.
  nonisolated static func recreateWorktreeIfMissing(
    worktree: Worktree,
    ownsWorktree: Bool,
    repoRoot: URL,
    gitClient: GitClientDependency
  ) async -> String? {
    let workingDirectory = worktree.workingDirectory
    guard ownsWorktree,
      !FileManager.default.fileExists(atPath: workingDirectory.path(percentEncoded: false))
    else { return nil }
    // Supacool lays worktrees out as `<baseDirectory>/<branch>`, so the branch
    // is the path's last component and re-adding it reconstructs the identical
    // path the captured session id was recorded under.
    let branchName = workingDirectory.lastPathComponent
    let baseDirectory = workingDirectory.deletingLastPathComponent()
    do {
      _ = try await gitClient.createWorktreeForExistingBranch(branchName, repoRoot, baseDirectory)
      return nil
    } catch {
      return "The worktree for this session was deleted and couldn't be recreated "
        + "(branch \"\(branchName)\" may be gone): \(error.localizedDescription). "
        + "Use Rerun to start fresh."
    }
  }

  /// True when the session backs onto a worktree it owns, rather than running
  /// straight in the repository root. Mirrors `cleanupPlan`, which only ever
  /// `git worktree remove`s when `worktreeID != repositoryID` — so this is
  /// exactly the set of sessions whose directory can vanish under them.
  nonisolated static func ownsWorktree(_ session: AgentSession) -> Bool {
    session.worktreeID != session.repositoryID
  }

  static func resumeWorktree(
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
