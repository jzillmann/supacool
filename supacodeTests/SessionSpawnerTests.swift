import ConcurrencyExtras
import Dependencies
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Testing

@testable import Supacool

/// Direct exercises against `SessionSpawner.spawnLocal` — the worktree-
/// resolution + terminal-spawn + AgentSession-construction path that
/// used to be inline in `NewTerminalFeature.handleLocalCreate`.
@MainActor
struct SessionSpawnerTests {
  // MARK: - Command construction

  @Test(.dependencies) func repoRootClaudeSpawnsWithBypassFlag() async throws {
    let request = Self.makeRequest(
      selection: .repoRoot,
      agent: .claude,
      prompt: "Summarize the README"
    )
    let spawnedInput = LockIsolated<String?>(nil)
    try await withDependencies {
      $0.terminalClient.send = { command in
        if case .createTabWithInput(_, let input, _, _) = command {
          spawnedInput.setValue(input)
        }
      }
      $0.repoSync = RepoSyncClient(syncIfSafe: { _ in .skippedDirtyTree })
    } operation: {
      _ = try await SessionSpawner.spawnLocal(request)
    }
    #expect(spawnedInput.value == "claude --dangerously-skip-permissions 'Summarize the README'\r")
  }

  @Test(.dependencies) func codexAgentSpawnsWithCodexBinary() async throws {
    let request = Self.makeRequest(
      selection: .repoRoot,
      agent: .codex,
      prompt: "List the tests"
    )
    let spawnedInput = LockIsolated<String?>(nil)
    try await withDependencies {
      $0.terminalClient.send = { command in
        if case .createTabWithInput(_, let input, _, _) = command {
          spawnedInput.setValue(input)
        }
      }
      $0.repoSync = RepoSyncClient(syncIfSafe: { _ in .skippedDirtyTree })
    } operation: {
      _ = try await SessionSpawner.spawnLocal(request)
    }
    #expect(spawnedInput.value == "codex --dangerously-bypass-approvals-and-sandbox 'List the tests'\r")
  }

  @Test(.dependencies) func claudePlanModeSpawnsWithoutBypassFlag() async throws {
    let request = Self.makeRequest(
      selection: .repoRoot,
      agent: .claude,
      prompt: "Plan the refactor",
      planMode: true,
      bypassPermissions: true
    )
    let spawnedInput = LockIsolated<String?>(nil)
    try await withDependencies {
      $0.terminalClient.send = { command in
        if case .createTabWithInput(_, let input, _, _) = command {
          spawnedInput.setValue(input)
        }
      }
      $0.repoSync = RepoSyncClient(syncIfSafe: { _ in .skippedDirtyTree })
    } operation: {
      _ = try await SessionSpawner.spawnLocal(request)
    }
    #expect(spawnedInput.value == "claude --permission-mode plan 'Plan the refactor'\r")
  }

  // MARK: - Setup script flag

  @Test(.dependencies) func runSetupScriptIsTrueForWorktreeMode() async throws {
    let worktree = Worktree(
      id: "/tmp/repo/wt-x",
      name: "wt-x",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-x"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
    let repository = Self.makeRepository(worktrees: [worktree])
    let request = Self.makeRequest(
      repository: repository,
      selection: .existingWorktree(id: worktree.id),
      prompt: "Do the thing"
    )
    let runSetup = LockIsolated<Bool?>(nil)
    try await withDependencies {
      $0.terminalClient.send = { command in
        if case .createTabWithInput(_, _, let runSetupScriptIfNew, _) = command {
          runSetup.setValue(runSetupScriptIfNew)
        }
      }
      $0.repoSync = RepoSyncClient(syncIfSafe: { _ in .skippedDirtyTree })
    } operation: {
      _ = try await SessionSpawner.spawnLocal(request)
    }
    #expect(runSetup.value == true)
  }

  @Test(.dependencies) func runSetupScriptIsFalseForRepoRoot() async throws {
    let request = Self.makeRequest(selection: .repoRoot, prompt: "Do the thing")
    let runSetup = LockIsolated<Bool?>(nil)
    try await withDependencies {
      $0.terminalClient.send = { command in
        if case .createTabWithInput(_, _, let runSetupScriptIfNew, _) = command {
          runSetup.setValue(runSetupScriptIfNew)
        }
      }
      $0.repoSync = RepoSyncClient(syncIfSafe: { _ in .skippedDirtyTree })
    } operation: {
      _ = try await SessionSpawner.spawnLocal(request)
    }
    #expect(runSetup.value == false)
  }

  // MARK: - Pre-worktree origin fetch

  @Test(.dependencies) func newBranchFetchesOriginWhenEnabled() async throws {
    let request = Self.makeRequest(
      selection: .newBranch(name: "feat/x"),
      prompt: "Do the thing",
      fetchOriginBeforeCreation: true
    )
    let events = LockIsolated<[String]>([])
    try await withDependencies {
      $0.gitClient.automaticWorktreeBaseRef = { _ in "origin/main" }
      $0.gitClient.remoteNames = { _ in ["origin"] }
      $0.gitClient.fetchRemote = { remote, _ in
        events.withValue { $0.append("fetch:\(remote)") }
      }
      $0.gitClient.createWorktree = { name, repoRoot, _, _, _, baseRef in
        events.withValue { $0.append("createWorktree:\(name):\(baseRef)") }
        return Worktree(
          id: "\(repoRoot.path)/worktrees/\(name)",
          name: name,
          detail: "",
          workingDirectory: URL(fileURLWithPath: "\(repoRoot.path)/worktrees/\(name)"),
          repositoryRootURL: repoRoot,
        )
      }
      $0.terminalClient.send = { _ in }
    } operation: {
      _ = try await SessionSpawner.spawnLocal(request)
    }
    #expect(events.value == ["fetch:origin", "createWorktree:feat/x:origin/main"])
  }

  @Test(.dependencies) func newBranchSkipsFetchWhenDisabled() async throws {
    let request = Self.makeRequest(
      selection: .newBranch(name: "feat/x"),
      prompt: "Do the thing",
      fetchOriginBeforeCreation: false
    )
    let fetchCalls = LockIsolated<Int>(0)
    try await withDependencies {
      $0.gitClient.automaticWorktreeBaseRef = { _ in "origin/main" }
      $0.gitClient.remoteNames = { _ in ["origin"] }
      $0.gitClient.fetchRemote = { _, _ in
        fetchCalls.withValue { $0 += 1 }
      }
      $0.gitClient.createWorktree = { name, repoRoot, _, _, _, _ in
        Worktree(
          id: "\(repoRoot.path)/worktrees/\(name)",
          name: name,
          detail: "",
          workingDirectory: URL(fileURLWithPath: "\(repoRoot.path)/worktrees/\(name)"),
          repositoryRootURL: repoRoot,
        )
      }
      $0.terminalClient.send = { _ in }
    } operation: {
      _ = try await SessionSpawner.spawnLocal(request)
    }
    #expect(fetchCalls.value == 0)
  }

  @Test(.dependencies) func newBranchFetchFailureDoesNotBlockCreation() async throws {
    struct FetchFailure: Error {}
    let request = Self.makeRequest(
      selection: .newBranch(name: "feat/x"),
      prompt: "Do the thing",
      fetchOriginBeforeCreation: true
    )
    let createWorktreeRan = LockIsolated<Bool>(false)
    try await withDependencies {
      $0.gitClient.automaticWorktreeBaseRef = { _ in "origin/main" }
      $0.gitClient.remoteNames = { _ in ["origin"] }
      $0.gitClient.fetchRemote = { _, _ in throw FetchFailure() }
      $0.gitClient.createWorktree = { name, repoRoot, _, _, _, _ in
        createWorktreeRan.withValue { $0 = true }
        return Worktree(
          id: "\(repoRoot.path)/worktrees/\(name)",
          name: name,
          detail: "",
          workingDirectory: URL(fileURLWithPath: "\(repoRoot.path)/worktrees/\(name)"),
          repositoryRootURL: repoRoot,
        )
      }
      $0.terminalClient.send = { _ in }
    } operation: {
      _ = try await SessionSpawner.spawnLocal(request)
    }
    #expect(createWorktreeRan.value == true)
  }

  // MARK: - PR-armed existing-branch flow

  @Test(.dependencies) func prArmedExistingBranchFetchesRefspecThenWorktreeAdds() async throws {
    let branchName = "refactor/overview-card-consistency"
    let prContext = PullRequestContext(
      parsed: ParsedPullRequestURL(
        url: "https://github.com/acme/widgets/pull/2349",
        owner: "acme",
        repo: "widgets",
        number: 2349
      ),
      metadata: SupacoolPRMetadata(
        title: "refactor",
        headRefName: branchName,
        baseRefName: "main",
        headRepositoryOwner: "acme",
        state: "OPEN",
        isDraft: false
      ),
      matchedRepositoryID: "/tmp/repo",
      isFork: false
    )
    let request = Self.makeRequest(
      selection: .existingBranch(name: branchName),
      prompt: "Analyze PR",
      // Deliberately OFF — PR-armed path must force-fetch anyway.
      fetchOriginBeforeCreation: false,
      pullRequestLookup: .resolved(prContext)
    )
    let events = LockIsolated<[String]>([])
    try await withDependencies {
      $0.gitClient.remoteNames = { _ in ["origin"] }
      $0.gitClient.fetchRemote = { remote, _ in
        events.withValue { $0.append("fetchRemote:\(remote)") }
      }
      $0.gitClient.branchExists = { name, _ in
        events.withValue { $0.append("branchExists:\(name)") }
        return false
      }
      $0.gitClient.fetchBranchRefspec = { name, remote, _ in
        events.withValue { $0.append("fetchRefspec:\(remote):\(name)") }
      }
      $0.gitClient.createWorktreeForExistingBranch = { name, repoRoot, _ in
        events.withValue { $0.append("createForExisting:\(name)") }
        return Worktree(
          id: "\(repoRoot.path)/worktrees/\(name)",
          name: name,
          detail: "",
          workingDirectory: URL(fileURLWithPath: "\(repoRoot.path)/worktrees/\(name)"),
          repositoryRootURL: repoRoot,
        )
      }
      $0.terminalClient.send = { _ in }
    } operation: {
      _ = try await SessionSpawner.spawnLocal(request)
    }
    #expect(events.value == [
      "fetchRemote:origin",
      "branchExists:\(branchName)",
      "fetchRefspec:origin:\(branchName)",
      "createForExisting:\(branchName)",
    ])
  }

  @Test(.dependencies) func existingBranchFallsBackToRefspecWhenMissing() async throws {
    let request = Self.makeRequest(
      selection: .existingBranch(name: "feat/remote-only"),
      prompt: "work on a branch",
      fetchOriginBeforeCreation: true
    )
    let events = LockIsolated<[String]>([])
    try await withDependencies {
      $0.gitClient.remoteNames = { _ in ["origin"] }
      $0.gitClient.fetchRemote = { remote, _ in
        events.withValue { $0.append("fetchRemote:\(remote)") }
      }
      $0.gitClient.branchExists = { _, _ in false }
      $0.gitClient.fetchBranchRefspec = { name, remote, _ in
        events.withValue { $0.append("fetchRefspec:\(remote):\(name)") }
      }
      $0.gitClient.createWorktreeForExistingBranch = { name, repoRoot, _ in
        events.withValue { $0.append("createForExisting:\(name)") }
        return Worktree(
          id: "\(repoRoot.path)/worktrees/\(name)",
          name: name,
          detail: "",
          workingDirectory: URL(fileURLWithPath: "\(repoRoot.path)/worktrees/\(name)"),
          repositoryRootURL: repoRoot,
        )
      }
      $0.terminalClient.send = { _ in }
    } operation: {
      _ = try await SessionSpawner.spawnLocal(request)
    }
    #expect(events.value == [
      "fetchRemote:origin",
      "fetchRefspec:origin:feat/remote-only",
      "createForExisting:feat/remote-only",
    ])
  }

  // MARK: - Helpers

  private static func makeRepository(
    id: String = "/tmp/repo",
    name: String = "test-repo",
    worktrees: [Worktree] = []
  ) -> Repository {
    Repository(
      id: id,
      rootURL: URL(fileURLWithPath: id),
      name: name,
      worktrees: IdentifiedArray(uniqueElements: worktrees)
    )
  }

  private static func makeRequest(
    repository: Repository = makeRepository(),
    selection: WorkspaceSelection = .repoRoot,
    agent: AgentType? = .claude,
    prompt: String = "Do the thing",
    planMode: Bool = false,
    bypassPermissions: Bool = true,
    fetchOriginBeforeCreation: Bool = false,
    pullRequestLookup: PullRequestLookupState = .idle
  ) -> SessionSpawner.LocalRequest {
    SessionSpawner.LocalRequest(
      sessionID: UUID(),
      repository: repository,
      selection: selection,
      agent: agent,
      prompt: prompt,
      planMode: planMode,
      bypassPermissions: bypassPermissions,
      fetchOriginBeforeCreation: fetchOriginBeforeCreation,
      rerunOwnedWorktreeID: nil,
      pullRequestLookup: pullRequestLookup,
      suggestedDisplayName: nil,
      removeBackingWorktreeOnDelete: false
    )
  }
}
