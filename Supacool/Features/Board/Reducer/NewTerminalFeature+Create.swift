import ComposableArchitecture
import Foundation
import IdentifiedCollections

/// The local (git-backed) and remote (ssh + tmux) create paths plus the
/// initial-reference seeding they share, mechanically extracted from
/// `NewTerminalFeature.swift`; behavior identical.
extension NewTerminalFeature {
  // MARK: - Local create

  /// Git-backed spawn path: validates the repo+workspace selection, then
  /// (in an effect) creates or adopts a `Worktree`, spawns the terminal
  /// tab, and emits `.sessionReady` with an `AgentSession`.
  ///
  /// Sibling of `handleRemoteCreate` — keep their validation rules and
  /// agent-command composition in sync when touching either.
  func handleLocalCreate(state: inout State) -> Effect<Action> {
    let trimmedPrompt = state.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let repoID = state.selectedRepositoryID,
      let repository = state.availableRepositories[id: repoID]
    else {
      state.validationMessage = "Pick a repository."
      return .none
    }

    if let message = Self.localCreateValidationMessage(
      state: state,
      repository: repository,
      trimmedPrompt: trimmedPrompt
    ) {
      state.validationMessage = message
      return .none
    }
    var selection = state.selectedWorkspace
    state.validationMessage = nil
    // Sheet dismisses immediately on Create (parent flips
    // `state.newTerminalSheet = nil` upon receiving `.spawnRequested`),
    // so we don't bother flipping `isCreating` — the spinner would
    // never be visible.

    // Honor the submitted Scope exactly. Earlier builds silently promoted
    // Main + agent + prompt submissions to a generated worktree branch,
    // which made the UI lie and could derive branch names from pasted file
    // paths. SessionSpawner still tries a best-effort repo-root sync, but
    // it must not override an explicit Main selection.
    selection = Self.resolveSubmittedSelection(
      selection: selection,
      agent: state.agent,
      trimmedPrompt: trimmedPrompt,
      rerunOwnedWorktreeID: state.rerunOwnedWorktreeID
    )

    // When the sheet was pre-configured from a pasted PR URL, we
    // already have a high-quality human title ready. Pass it through
    // so the card shows "PR #42: Fix the widget" from moment one,
    // instead of the URL hostname that the prompt slice would yield.
    // Linear ticket titles work the same way — when the prompt names
    // a ticket and we resolved its title, the card opens with
    // "CEN-6690 · Streamline foobar" instead of the prompt slice.
    let suggestedDisplayName: String? = Self.suggestedDisplayName(state: state)

    let agent = state.agent
    let planMode = agent?.supportsPlanMode == true && state.planMode
    let remoteControl = agent?.supportsRemoteControl == true && state.remoteControl
    let remoteControlName: String? = {
      let trimmed = state.remoteControlName.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }()
    let model = state.normalizedModel
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
      remoteControl: remoteControl,
      remoteControlName: remoteControlName,
      model: model,
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

    var effects: [Effect<Action>] = []
    if let bookmark = Self.bookmarkToSave(state: state, request: request) {
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
      .send(
        .delegate(
          .spawnRequested(
            request,
            displayName: placeholderDisplayName,
            draftSnapshot: Self.draftSnapshot(state: state)
          )
        )
      )
    )
    return .merge(effects)
  }

  /// Form validation for the local create path: workspace selection,
  /// prompt, and bookmark-name rules. Returns the message to surface,
  /// or nil when the submission is valid.
  private static func localCreateValidationMessage(
    state: State,
    repository: Repository,
    trimmedPrompt: String
  ) -> String? {
    switch state.selectedWorkspace {
    case .repoRoot:
      break
    case .existingWorktree(let id):
      guard repository.worktrees.contains(where: { $0.id == id }) else {
        return "Picked worktree no longer exists."
      }
    case .existingBranch(let name):
      let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else {
        return "Pick a branch."
      }
      guard !trimmed.contains(where: \.isWhitespace) else {
        return "Branch names can't contain spaces."
      }
    case .newBranch(let name):
      let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else {
        return "Branch name required."
      }
      guard !trimmed.contains(where: \.isWhitespace) else {
        return "Branch names can't contain spaces."
      }
    }
    if state.agent != nil && trimmedPrompt.isEmpty {
      return "Prompt required."
    }
    if state.saveAsBookmark {
      let trimmedName = state.bookmarkName.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmedName.isEmpty else {
        return "Bookmark name required."
      }
    }
    return nil
  }

  /// The bookmark to persist alongside the spawn when "Save as bookmark"
  /// was ticked; nil otherwise. Mirrors the submitted request's values.
  private static func bookmarkToSave(
    state: State,
    request: SessionSpawner.LocalRequest
  ) -> Bookmark? {
    guard state.saveAsBookmark else { return nil }
    let trimmedName = state.bookmarkName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else { return nil }
    let worktreeMode: Bookmark.WorktreeMode = {
      switch request.selection {
      case .repoRoot: return .repoRoot
      case .newBranch, .existingBranch, .existingWorktree: return .newWorktree
      }
    }()
    return Bookmark(
      id: state.editingBookmarkID ?? UUID(),
      repositoryID: request.repository.id,
      name: trimmedName,
      prompt: request.prompt,
      agent: request.agent,
      worktreeMode: worktreeMode,
      planMode: request.planMode,
      remoteControl: request.remoteControl,
      model: request.model
    )
  }

  /// A `Draft`-shaped snapshot of the submitted values so the parent can
  /// attach it to the failure tray card on spawn error. Tap on that card
  /// resurrects the sheet via the same path drafts use
  /// (`NewTerminalFeature.State(availableRepositories:, resuming:)`).
  /// Preserving `editingDraftID` here means a reopened-then-Save-Draft
  /// cycle upserts the same Draft instead of leaving an orphan.
  private static func draftSnapshot(state: State) -> Draft {
    let now = Date()
    return Draft(
      id: state.editingDraftID ?? UUID(),
      repositoryID: state.selectedRepositoryID,
      prompt: state.prompt,
      agent: state.agent,
      workspaceQuery: state.workspaceQuery,
      planMode: state.planMode,
      remoteControl: state.remoteControl,
      model: state.normalizedModel,
      createdAt: now,
      updatedAt: now
    )
  }

  // MARK: - Remote create

  /// Fork of `createButtonTapped` for remote sessions: no git, no
  /// worktree. Finds (or creates) a `RemoteWorkspace` for the entered
  /// path, builds a shim `Worktree` + `RemoteSpawnInvocation`, sends
  /// `.createRemoteTab`, and produces the `AgentSession` with the
  /// remote fields populated so the board classifier picks it up as
  /// `.disconnected` the moment the link drops.
  func handleRemoteCreate(
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

    return spawnRemoteSessionEffect(
      state: state,
      host: host,
      workspace: workspace,
      trimmedPath: trimmedPath,
      trimmedPrompt: trimmedPrompt,
      localSocketPath: localSocketPath,
      repositoryIDOverride: repositoryIDOverride,
      repositoryRemoteTargetID: repositoryRemoteTargetID
    )
  }

  /// Assembly half of the remote create path: builds the agent command,
  /// the ssh + tmux spawn invocation, the shim `Worktree`, and the
  /// `AgentSession`, then returns the effect that creates the remote
  /// tab. All validation and state mutation happened in
  /// `handleRemoteCreate` before delegating here.
  private func spawnRemoteSessionEffect(
    state: State,
    host: RemoteHost,
    workspace: RemoteWorkspace,
    trimmedPath: String,
    trimmedPrompt: String,
    localSocketPath: String,
    repositoryIDOverride: Repository.ID?,
    repositoryRemoteTargetID: RepositoryRemoteTarget.ID?
  ) -> Effect<Action> {
    let sessionID = UUID()
    let tmuxSessionName = "supacool-\(sessionID.uuidString.lowercased())"
    let worktreeKey = "remote:\(host.sshAlias):\(trimmedPath)"
    let repositoryID = repositoryIDOverride ?? worktreeKey
    let agent = state.agent
    let planMode = agent?.supportsPlanMode == true && state.planMode
    let remoteControl = agent?.supportsRemoteControl == true && state.remoteControl
    let remoteControlName: String? = {
      let trimmed = state.remoteControlName.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }()
    let model = state.normalizedModel
    let bypassPermissions =
      UserDefaults.standard.object(forKey: "supacool.bypassPermissions") as? Bool ?? true

    let agentCommand: String?
    if let agent, !trimmedPrompt.isEmpty {
      agentCommand = agent.command(
        prompt: trimmedPrompt,
        bypassPermissions: bypassPermissions,
        planMode: planMode,
        remoteControl: remoteControl,
        remoteControlName: remoteControlName,
        model: model
      )
    } else if let agent {
      agentCommand = agent.commandWithoutPrompt(
        bypassPermissions: bypassPermissions,
        planMode: planMode,
        remoteControl: remoteControl,
        remoteControlName: remoteControlName,
        model: model
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

    @Shared(.repositorySettings(URL(fileURLWithPath: repositoryID))) var repositorySettings
    let seededReferences = initialReferences(
      prompt: trimmedPrompt,
      allowedPrefixes: parseLinearTeamKeys(repositorySettings.linearTeamKeys),
      pullRequestLookup: state.pullRequestLookup
    )

    let session = AgentSession(
      id: sessionID,
      repositoryID: repositoryID,
      worktreeID: worktreeKey,
      agent: agent,
      initialPrompt: trimmedPrompt,
      displayName: Self.suggestedDisplayName(state: state),
      removeBackingWorktreeOnDelete: false,
      planMode: planMode,
      remoteControl: remoteControl,
      model: model,
      references: seededReferences,
      referencesScannedAt: seededReferences.isEmpty ? nil : Date(),
      remoteWorkspaceID: workspace.id,
      remoteHostID: host.id,
      repositoryRemoteTargetID: repositoryRemoteTargetID,
      tmuxSessionName: tmuxSessionName
    )

    let terminalClient = self.terminalClient
    return .run { send in
      await terminalClient.send(
        .createRemoteTab(
          worktreeShim,
          command: sshCommand,
          id: sessionID,
          surfaceID: sessionID,
        )
      )
      await send(.sessionReady(session))
    }
  }

  private func initialReferences(
    prompt: String,
    allowedPrefixes: Set<String>,
    pullRequestLookup: PullRequestLookupState
  ) -> [SessionReference] {
    var refs = scannerClient.scanText(prompt, allowedPrefixes)
    if case .resolved(let context) = pullRequestLookup {
      refs.append(
        .pullRequest(
          owner: context.parsed.owner,
          repo: context.parsed.repo,
          number: context.parsed.number,
          state: nil,
          title: context.metadata.title
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
}
