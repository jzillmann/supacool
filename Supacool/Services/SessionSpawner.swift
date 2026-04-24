import ComposableArchitecture
import Foundation

private nonisolated let sessionSpawnerLogger = SupaLogger("Supacool.SessionSpawner")

/// Shared spawn path for local (git-backed) agent sessions. Owns the
/// worktree-resolution + terminal-spawn + AgentSession construction flow
/// that used to live inline in `NewTerminalFeature.handleLocalCreate`.
///
/// Two callers today:
/// - `NewTerminalFeature.handleLocalCreate` — full-featured path with PR
///   context, rerun ownership, and user-driven branch picking.
/// - `BoardFeature.bookmarkTapped` — simpler path; bookmarks only exercise
///   `.repoRoot` and `.newBranch(auto-named)`, everything else defaults.
///
/// Validation stays at the call site. This helper trusts its request.
enum SessionSpawner {
  struct LocalRequest: Equatable, Sendable {
    let sessionID: UUID
    let repository: Repository
    let selection: WorkspaceSelection
    let agent: AgentType?
    let prompt: String
    let planMode: Bool
    let bypassPermissions: Bool
    let fetchOriginBeforeCreation: Bool
    let rerunOwnedWorktreeID: String?
    let pullRequestLookup: PullRequestLookupState
    let suggestedDisplayName: String?
    let removeBackingWorktreeOnDelete: Bool
  }

  /// Resolves or creates the backing worktree, spawns the terminal tab
  /// (with the agent command piped in), and returns the constructed
  /// `AgentSession`. Throws on git / terminal errors — caller converts
  /// to a user-facing validation message.
  @MainActor
  static func spawnLocal(_ request: LocalRequest) async throws -> AgentSession {
    @Dependency(GitClientDependency.self) var gitClient
    @Dependency(TerminalClient.self) var terminalClient
    @Dependency(RepoSyncClient.self) var repoSyncClient

    let repository = request.repository
    let selection = request.selection
    let worktree = try await resolveWorktree(
      selection: selection,
      repository: repository,
      fetchOriginBeforeCreation: request.fetchOriginBeforeCreation,
      pullRequestLookup: request.pullRequestLookup,
      gitClient: gitClient,
      repoSyncClient: repoSyncClient
    )

    let input = buildInput(
      agent: request.agent,
      prompt: request.prompt,
      bypassPermissions: request.bypassPermissions,
      planMode: request.planMode
    )
    await terminalClient.send(
      .createTabWithInput(
        worktree,
        input: input,
        // Setup scripts are worktree-scoped by contract; running them
        // inside the main repo (directory-mode session, where
        // `worktree.workingDirectory == repositoryRootURL`) has blown
        // away node_modules in repos whose setup script is pnpm/yarn-
        // based. WorktreeTerminalManager has the same guard, but
        // expressing it here keeps the call site honest.
        runSetupScriptIfNew: worktree.workingDirectory.standardizedFileURL
          != worktree.repositoryRootURL.standardizedFileURL,
        id: request.sessionID
      )
    )

    return AgentSession(
      id: request.sessionID,
      repositoryID: repository.id,
      worktreeID: worktree.id,
      agent: request.agent,
      initialPrompt: request.prompt,
      displayName: request.suggestedDisplayName,
      removeBackingWorktreeOnDelete: request.removeBackingWorktreeOnDelete,
      planMode: request.planMode
    )
  }

  // MARK: - Internals

  private static func resolveWorktree(
    selection: WorkspaceSelection,
    repository: Repository,
    fetchOriginBeforeCreation: Bool,
    pullRequestLookup: PullRequestLookupState,
    gitClient: GitClientDependency,
    repoSyncClient: RepoSyncClient
  ) async throws -> Worktree {
    switch selection {
    case .newBranch(let rawName):
      return try await createWorktreeForNewBranch(
        rawName: rawName,
        repository: repository,
        fetchOriginBeforeCreation: fetchOriginBeforeCreation,
        gitClient: gitClient
      )

    case .existingBranch(let rawName):
      return try await createWorktreeForExistingBranch(
        rawName: rawName,
        repository: repository,
        fetchOriginBeforeCreation: fetchOriginBeforeCreation,
        pullRequestLookup: pullRequestLookup,
        gitClient: gitClient
      )

    case .existingWorktree(let id):
      // Identifiable on Worktree is @MainActor-isolated.
      let picked: Worktree? = await MainActor.run {
        repository.worktrees.first { $0.id == id }
      }
      guard let picked else { throw NewTerminalError.worktreeMissing }
      return picked

    case .repoRoot:
      // Pre-flight: try to fast-forward the repo root to origin/<default>
      // before we hand the terminal to the user. Supacool's model is that
      // users don't modify the root directly — worktrees are where work
      // happens — so "on investigate, put me on latest main" is the
      // expected behavior. Conservative guards in the client; failure
      // never blocks the spawn.
      let syncOutcome = await repoSyncClient.syncIfSafe(repository.rootURL)
      sessionSpawnerLogger.info(
        "Repo-root pre-flight sync for "
          + "\(repository.rootURL.path(percentEncoded: false)): \(syncOutcome)"
      )
      let rootURL = repository.rootURL.standardizedFileURL
      return await MainActor.run {
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
  }

  private static func createWorktreeForNewBranch(
    rawName: String,
    repository: Repository,
    fetchOriginBeforeCreation: Bool,
    gitClient: GitClientDependency
  ) async throws -> Worktree {
    let branchName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    let baseRef = await gitClient.automaticWorktreeBaseRef(repository.rootURL) ?? "HEAD"
    if fetchOriginBeforeCreation {
      let remotes = (try? await gitClient.remoteNames(repository.rootURL)) ?? []
      if let matchedRemote = baseRef.supacoolMatchingRemote(from: remotes) {
        do {
          try await gitClient.fetchRemote(matchedRemote, repository.rootURL)
        } catch {
          sessionSpawnerLogger.warning(
            "Pre-worktree fetch \(matchedRemote) failed for "
              + "\(repository.rootURL.path(percentEncoded: false)): \(error)"
          )
        }
      }
    }
    let baseDirectory = SupacoolPaths.worktreeBaseDirectory(
      for: repository.rootURL,
      globalDefaultPath: nil,
      repositoryOverridePath: nil
    )
    return try await gitClient.createWorktree(
      branchName,
      repository.rootURL,
      baseDirectory,
      false,
      false,
      baseRef
    )
  }

  private static func createWorktreeForExistingBranch(
    rawName: String,
    repository: Repository,
    fetchOriginBeforeCreation: Bool,
    pullRequestLookup: PullRequestLookupState,
    gitClient: GitClientDependency
  ) async throws -> Worktree {
    let branchName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    // PR-armed create: the PR banner pinned this branch name, so we
    // *know* it lives on the remote. Force the fetch even if the user
    // has the global setting disabled.
    let isPRArmed = NewTerminalFeature.isPRArmedExistingBranch(
      pullRequestLookup: pullRequestLookup,
      branchName: branchName
    )
    let shouldFetchRemote = fetchOriginBeforeCreation || isPRArmed
    let remotes = shouldFetchRemote
      ? ((try? await gitClient.remoteNames(repository.rootURL)) ?? [])
      : []
    if shouldFetchRemote, let firstRemote = remotes.first {
      do {
        try await gitClient.fetchRemote(firstRemote, repository.rootURL)
      } catch {
        sessionSpawnerLogger.warning(
          "Pre-worktree fetch \(firstRemote) failed for "
            + "\(repository.rootURL.path(percentEncoded: false)): \(error)"
        )
      }
    }
    // The first fetch may have failed silently (offline / auth), and
    // modern git's `worktree add` DWIM only triggers once the
    // remote-tracking ref is present. If the local branch still doesn't
    // resolve, do a targeted refspec fetch that creates the local
    // branch directly.
    let localBranchPresent =
      (try? await gitClient.branchExists(branchName, repository.rootURL)) ?? false
    if !localBranchPresent {
      let resolvedRemotes: [String]
      if remotes.isEmpty {
        resolvedRemotes = (try? await gitClient.remoteNames(repository.rootURL)) ?? []
      } else {
        resolvedRemotes = remotes
      }
      guard let firstRemote = resolvedRemotes.first else {
        throw NewTerminalError.branchNotFoundAfterFetch(name: branchName)
      }
      do {
        try await gitClient.fetchBranchRefspec(
          branchName,
          firstRemote,
          repository.rootURL
        )
      } catch {
        sessionSpawnerLogger.warning(
          "Refspec fetch \(firstRemote) \(branchName):\(branchName) failed for "
            + "\(repository.rootURL.path(percentEncoded: false)): \(error)"
        )
        throw NewTerminalError.branchNotFoundAfterFetch(name: branchName)
      }
    }
    let baseDirectory = SupacoolPaths.worktreeBaseDirectory(
      for: repository.rootURL,
      globalDefaultPath: nil,
      repositoryOverridePath: nil
    )
    // Common rerun gotcha: the previous session's worktree directory is
    // still on disk (git's record was dropped, or supacode's repo cache
    // hasn't refreshed yet). If the path looks like a live git worktree,
    // adopt it instead of failing.
    if let adopted = NewTerminalFeature.adoptExistingWorktreeDirectory(
      branchName: branchName,
      baseDirectory: baseDirectory,
      repoRootURL: repository.rootURL
    ) {
      return adopted
    }
    return try await gitClient.createWorktreeForExistingBranch(
      branchName,
      repository.rootURL,
      baseDirectory
    )
  }

  private static func buildInput(
    agent: AgentType?,
    prompt: String,
    bypassPermissions: Bool,
    planMode: Bool
  ) -> String {
    switch (agent, prompt.isEmpty) {
    case (let agent?, false):
      return agent.command(
        prompt: prompt,
        bypassPermissions: bypassPermissions,
        planMode: planMode
      ) + "\r"
    case (let agent?, true):
      return agent.commandWithoutPrompt(
        bypassPermissions: bypassPermissions,
        planMode: planMode
      ) + "\r"
    case (nil, false):
      return prompt + "\r"
    case (nil, true):
      return ""
    }
  }
}
