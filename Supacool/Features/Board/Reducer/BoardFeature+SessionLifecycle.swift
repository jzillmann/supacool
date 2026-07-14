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
    return .run {
      [terminalClient, piSettingsClient, gitClient, agent, worktree, repository] send in
      // Guardrail: never launch the resume command into a directory that no
      // longer exists. If this is an owns-worktree session whose checkout was
      // deleted (trash → restore), put the worktree back at its exact original
      // path first — otherwise the shell falls back to an unrelated cwd and
      // `claude --resume` reports "No conversation found" even though the
      // transcript is intact. See `recreateWorktreeIfMissing`.
      do {
        try await Self.recreateWorktreeIfMissing(
          at: worktree.workingDirectory,
          repository: repository,
          gitClient: gitClient
        )
      } catch {
        await send(
          .resumeFailed(
            id: id,
            message: "Couldn't recreate worktree at "
              + "\(worktree.workingDirectory.path(percentEncoded: false)): "
              + error.localizedDescription
          )
        )
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

  /// Re-adds the session's backing worktree checkout from its (surviving)
  /// branch when the directory is gone — the trash-then-restore case.
  ///
  /// Trashing an `owns-worktree` session deletes the checkout immediately
  /// (`git worktree remove`, which keeps the branch ref). Restore only
  /// re-adds the card, so a later Resume would launch `claude --resume <id>`
  /// in a directory that no longer exists; the shell falls back to an
  /// unrelated cwd, and because `claude --resume` scopes its lookup to the
  /// current directory's project hash, the intact conversation becomes
  /// unfindable — the opaque "No conversation found". Re-adding the worktree
  /// at its *exact original path* (`baseDirectory/branchName`, which is how
  /// `worktreeID` was formed) restores the hash so resume resolves.
  ///
  /// No-op for repo-root sessions (`worktreeURL == repo root`) and when the
  /// directory already exists. Throws if `git worktree add` fails (e.g. the
  /// branch was deleted too) so callers can recreate-or-surface as they see
  /// fit.
  static func recreateWorktreeIfMissing(
    at worktreeURL: URL,
    repository: Repository,
    gitClient: GitClientDependency
  ) async throws {
    let standardized = worktreeURL.standardizedFileURL
    guard standardized != repository.rootURL.standardizedFileURL else { return }
    guard
      !FileManager.default.fileExists(
        atPath: standardized.path(percentEncoded: false)
      )
    else { return }
    _ = try await gitClient.createWorktreeForExistingBranch(
      standardized.lastPathComponent,
      repository.rootURL,
      standardized.deletingLastPathComponent()
    )
  }
}
