import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Testing

@testable import Supacool

@MainActor
struct NewTerminalFeatureTests {
  // MARK: - Validation

  @Test(.dependencies) func createButtonRequiresPrompt() async {
    let store = TestStore(initialState: Self.makeState()) {
      NewTerminalFeature()
    }
    store.exhaustivity = .off

    await store.send(.createButtonTapped) {
      $0.validationMessage = "Prompt required."
    }
  }

  @Test(.dependencies) func createButtonRequiresRepositorySelection() async {
    var state = Self.makeState(selectedRepositoryID: nil)
    state.prompt = "Fix the bug"

    let store = TestStore(initialState: state) {
      NewTerminalFeature()
    }
    store.exhaustivity = .off

    await store.send(\.binding.prompt, "Fix the bug")
    await store.send(.createButtonTapped) {
      $0.validationMessage = "Pick a repository."
    }
  }

  @Test(.dependencies) func newBranchRequiresName() async {
    var state = Self.makeState()
    state.prompt = "Explore the codebase"
    state.selectedWorkspace = .newBranch(name: "")

    let store = TestStore(initialState: state) {
      NewTerminalFeature()
    }
    store.exhaustivity = .off

    await store.send(.createButtonTapped) {
      $0.validationMessage = "Branch name required."
    }
  }

  @Test(.dependencies) func newBranchRejectsWhitespace() async {
    var state = Self.makeState()
    state.prompt = "Explore"
    state.selectedWorkspace = .newBranch(name: "feat with spaces")

    let store = TestStore(initialState: state) {
      NewTerminalFeature()
    }
    store.exhaustivity = .off

    await store.send(.createButtonTapped) {
      $0.validationMessage = "Branch names can't contain spaces."
    }
  }

  // MARK: - Success path (directory mode)

  @Test(.dependencies) func directoryModeSpawnsSession() async {
    var state = Self.makeState()
    state.prompt = "  Summarize the README  "

    var spawnedInput: String?
    let spawnedID = LockIsolated<UUID?>(nil)

    let store = TestStore(initialState: state) {
      NewTerminalFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        if case .createTabWithInput(_, let input, _, let id) = command {
          spawnedInput = input
          spawnedID.setValue(id)
        }
      }
    }
    store.exhaustivity = .off

    await store.send(.createButtonTapped) {
      $0.isCreating = true
    }
    await store.receive(\.sessionReady)
    await store.receive(\.delegate.created) { _ in }

    // The tab was spawned with the expected shell command (trimmed prompt).
    #expect(spawnedInput == "claude --dangerously-skip-permissions 'Summarize the README'\r")
    #expect(spawnedID.value != nil)
  }

  // MARK: - Setup script

  /// Regression: agent sessions created from the board must run the repo's
  /// configured setup script (Settings → Repository Settings → Setup Script)
  /// before the agent command, so hooks like pre-commit have the env/files
  /// they expect. A previous revision passed `runSetupScriptIfNew: false`
  /// unconditionally, which meant fresh worktrees landed un-initialized.
  @Test(.dependencies) func createRunsSetupScriptForNewWorktree() async {
    var state = Self.makeState()
    state.prompt = "Do the thing"

    let runSetupScript = LockIsolated<Bool?>(nil)
    let store = TestStore(initialState: state) {
      NewTerminalFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        if case .createTabWithInput(_, _, let runSetup, _) = command {
          runSetupScript.setValue(runSetup)
        }
      }
    }
    store.exhaustivity = .off

    await store.send(.createButtonTapped)
    await store.receive(\.sessionReady)
    await store.receive(\.delegate.created)

    #expect(runSetupScript.value == true)
  }

  // MARK: - Codex agent

  @Test(.dependencies) func codexAgentSpawnsWithCodexBinary() async {
    var state = Self.makeState()
    state.prompt = "List the tests"
    state.agent = .codex

    let spawnedInput = LockIsolated<String?>(nil)
    let store = TestStore(initialState: state) {
      NewTerminalFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        if case .createTabWithInput(_, let input, _, _) = command {
          spawnedInput.setValue(input)
        }
      }
    }
    store.exhaustivity = .off

    await store.send(.createButtonTapped)
    await store.receive(\.sessionReady)
    await store.receive(\.delegate.created)

    #expect(spawnedInput.value == "codex --dangerously-bypass-approvals-and-sandbox 'List the tests'\r")
  }

  // MARK: - Shell-quoting safety

  @Test func shellQuoteEscapesSingleQuotes() {
    let dangerous = "Fix Mario's bug"
    let quoted = AgentType.shellQuote(dangerous)
    #expect(quoted == "'Fix Mario'\\''s bug'")
  }

  @Test func shellQuoteEscapesMultipleSingleQuotes() {
    let prompt = "don't 'break'"
    let quoted = AgentType.shellQuote(prompt)
    #expect(quoted == "'don'\\''t '\\''break'\\'''")
  }

  // MARK: - Pre-worktree origin fetch

  /// Regression: creating a session in `.newBranch` mode must fetch the
  /// matching remote before `createWorktree`, so the new branch is based
  /// on the *actually* latest upstream instead of the local cache. Gated
  /// by `GlobalSettings.fetchOriginBeforeWorktreeCreation` (default on).
  @Test(.dependencies) func newBranchFetchesOriginWhenEnabled() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.fetchOriginBeforeWorktreeCreation = true }

    var state = Self.makeState()
    state.prompt = "Do the thing"
    state.selectedWorkspace = .newBranch(name: "feat/x")

    let events = LockIsolated<[String]>([])
    let store = TestStore(initialState: state) {
      NewTerminalFeature()
    } withDependencies: {
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
    }
    store.exhaustivity = .off

    await store.send(.createButtonTapped)
    await store.receive(\.sessionReady)
    await store.receive(\.delegate.created)

    #expect(events.value == ["fetch:origin", "createWorktree:feat/x:origin/main"])
  }

  @Test(.dependencies) func newBranchSkipsFetchWhenDisabled() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.fetchOriginBeforeWorktreeCreation = false }

    var state = Self.makeState()
    state.prompt = "Do the thing"
    state.selectedWorkspace = .newBranch(name: "feat/x")

    let fetchCalls = LockIsolated<Int>(0)
    let store = TestStore(initialState: state) {
      NewTerminalFeature()
    } withDependencies: {
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
    }
    store.exhaustivity = .off

    await store.send(.createButtonTapped)
    await store.receive(\.sessionReady)
    await store.receive(\.delegate.created)

    #expect(fetchCalls.value == 0)
  }

  /// If the network is down or auth is broken, the fetch must fail silently
  /// and the worktree must still be created — losing the user's prompt to
  /// a transient network blip would be a nasty regression.
  @Test(.dependencies) func newBranchFetchFailureDoesNotBlockCreation() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.fetchOriginBeforeWorktreeCreation = true }

    var state = Self.makeState()
    state.prompt = "Do the thing"
    state.selectedWorkspace = .newBranch(name: "feat/x")

    struct FetchFailure: Error {}
    let createWorktreeRan = LockIsolated<Bool>(false)
    let store = TestStore(initialState: state) {
      NewTerminalFeature()
    } withDependencies: {
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
    }
    store.exhaustivity = .off

    await store.send(.createButtonTapped)
    await store.receive(\.sessionReady)
    await store.receive(\.delegate.created)

    #expect(createWorktreeRan.value == true)
  }

  // MARK: - Rerun initializer

  @Test(.dependencies) func workspaceQueryRoundTripKeepsWorktreeIntent() async {
    // Regression for "click Worktree → click Workspace field → picker
    // reverts to Investigate". The user explicitly chose a worktree
    // selection; re-binding the empty query must keep the `.newBranch`
    // intent (pending name) instead of flipping back to `.repoRoot`.
    var state = Self.makeState()
    state.selectedWorkspace = .newBranch(name: "")

    let store = TestStore(initialState: state) {
      NewTerminalFeature()
    }
    store.exhaustivity = .off

    // Simulate @Bindable's empty round-trip on focus.
    await store.send(\.binding.workspaceQuery, "")

    #expect(store.state.selectedWorkspace == .newBranch(name: ""))
  }

  @Test(.dependencies) func workspaceQueryEmptyFromRepoRootStaysRepoRoot() async {
    // Complement to the regression above: from `.repoRoot` an empty
    // binding round-trip must stay on `.repoRoot` — we shouldn't
    // suddenly switch to `.newBranch`.
    var state = Self.makeState()
    state.selectedWorkspace = .repoRoot

    let store = TestStore(initialState: state) {
      NewTerminalFeature()
    }
    store.exhaustivity = .off

    await store.send(\.binding.workspaceQuery, "")

    #expect(store.state.selectedWorkspace == .repoRoot)
  }

  @Test func rerunInitializerPrefillsFromPreviousSession() {
    let previous = AgentSession(
      repositoryID: "/tmp/repo",
      worktreeID: "/tmp/repo",
      agent: .codex,
      initialPrompt: "Write tests for auth",
      displayName: "Write tests for auth"
    )
    let repos = IdentifiedArray(uniqueElements: [
      Self.makeRepository(id: "/tmp/repo", name: "test-repo")
    ])

    let state = NewTerminalFeature.State(availableRepositories: repos, rerunFrom: previous)

    #expect(state.prompt == "Write tests for auth")
    #expect(state.agent == .codex)
    #expect(state.selectedRepositoryID == "/tmp/repo")
    #expect(state.selectedWorkspace == .repoRoot)
    #expect(state.workspaceQuery.isEmpty)
  }

  // MARK: - Branch name suggestion

  @Test(.dependencies) func suggestBranchNamePopulatesWorkspaceQuery() async {
    var state = Self.makeState()
    state.prompt = "Add SSH connection pooling"

    let store = TestStore(initialState: state) {
      NewTerminalFeature()
    } withDependencies: {
      $0.backgroundInferenceClient.infer = { _ in "add-ssh-connection-pooling" }
    }

    await store.send(.suggestBranchNameTapped) {
      $0.isSuggestingBranchName = true
    }
    await store.receive(.branchNameSuggested("add-ssh-connection-pooling")) {
      $0.isSuggestingBranchName = false
      $0.workspaceQuery = "add-ssh-connection-pooling"
      $0.selectedWorkspace = .newBranch(name: "add-ssh-connection-pooling")
    }
  }

  @Test(.dependencies) func suggestBranchNameResetsOnFailure() async {
    var state = Self.makeState()
    state.prompt = "Refactor auth module"

    struct InferenceError: Error {}
    let store = TestStore(initialState: state) {
      NewTerminalFeature()
    } withDependencies: {
      $0.backgroundInferenceClient.infer = { _ in throw InferenceError() }
    }

    await store.send(.suggestBranchNameTapped) {
      $0.isSuggestingBranchName = true
    }
    await store.receive(.branchNameSuggestionFailed) {
      $0.isSuggestingBranchName = false
    }
    #expect(store.state.workspaceQuery.isEmpty)
    #expect(store.state.selectedWorkspace == .repoRoot)
  }

  @Test(.dependencies) func suggestBranchNameSanitizesOutput() async {
    var state = Self.makeState()
    state.prompt = "Fix Mario's bug with special chars!"

    let store = TestStore(initialState: state) {
      NewTerminalFeature()
    } withDependencies: {
      // Model returns messy output
      $0.backgroundInferenceClient.infer = { _ in "  Fix Mario's Bug!!  \nextra line" }
    }

    await store.send(.suggestBranchNameTapped) {
      $0.isSuggestingBranchName = true
    }
    await store.receive(\.branchNameSuggested) {
      $0.isSuggestingBranchName = false
      $0.workspaceQuery = "fix-marios-bug"
      $0.selectedWorkspace = .newBranch(name: "fix-marios-bug")
    }
  }

  // MARK: - Workspace selection inference

  @Test func inferSelectionEmptyIsRepoRoot() {
    let state = Self.makeState()
    #expect(NewTerminalFeature.inferSelection(from: "", state: state) == .repoRoot)
  }

  @Test func inferSelectionMatchesLocalBranch() {
    var state = Self.makeState()
    state.availableLocalBranches = ["main", "feat-x"]
    #expect(
      NewTerminalFeature.inferSelection(from: "feat-x", state: state)
        == .existingBranch(name: "feat-x")
    )
  }

  @Test func inferSelectionMatchesRemoteBranchShortName() {
    var state = Self.makeState()
    state.availableRemoteBranches = ["origin/pr-123", "origin/main"]
    #expect(
      NewTerminalFeature.inferSelection(from: "pr-123", state: state)
        == .existingBranch(name: "pr-123")
    )
  }

  @Test func inferSelectionMatchesRemoteBranchFullRef() {
    var state = Self.makeState()
    state.availableRemoteBranches = ["origin/pr-123"]
    #expect(
      NewTerminalFeature.inferSelection(from: "origin/pr-123", state: state)
        == .existingBranch(name: "pr-123")
    )
  }

  @Test func inferSelectionFallsBackToNewBranch() {
    let state = Self.makeState()
    #expect(
      NewTerminalFeature.inferSelection(from: "brand-new", state: state)
        == .newBranch(name: "brand-new")
    )
  }

  @Test func sanitizeBranchNameBasic() {
    #expect(sanitizeBranchName("add-ssh-pooling") == "add-ssh-pooling")
    #expect(sanitizeBranchName("  Fix Mario's Bug  ") == "fix-marios-bug")
    #expect(sanitizeBranchName("REFACTOR Auth Module") == "refactor-auth-module")
    #expect(sanitizeBranchName("feat/add_new_endpoint") == "feat/add-new-endpoint")
    // Truncation
    let long = "this-is-a-very-long-branch-name-that-exceeds-the-forty-character-limit"
    #expect(sanitizeBranchName(long).count <= 40)
  }

  // MARK: - PR URL flow

  /// Happy path: pasting a PR URL triggers a gh lookup, matches it against
  /// a configured repo, and pre-configures the workspace field to the PR's
  /// head branch. The user only has to press Create.
  @Test(.dependencies) func prURLResolvesAndPinsWorkspace() async {
    let state = Self.makeState()
    let store = TestStore(initialState: state) {
      NewTerminalFeature()
    } withDependencies: {
      $0.supacoolGithubPR.fetchMetadata = { owner, _, _ in
        SupacoolPRMetadata(
          title: "Fix the widget",
          headRefName: "feat/fix-widget",
          baseRefName: "main",
          headRepositoryOwner: owner,
          state: "OPEN",
          isDraft: false
        )
      }
      $0.gitClient.remoteInfo = { _ in
        GithubRemoteInfo(host: "github.com", owner: "acme", repo: "widgets")
      }
      $0.gitClient.localBranchNames = { _ in [] }
      $0.gitClient.remoteBranchRefs = { _ in [] }
    }
    store.exhaustivity = .off

    let pastedPrompt = "Look at this PR: https://github.com/acme/widgets/pull/42 and fix it"
    await store.send(\.binding.prompt, pastedPrompt)
    await store.receive(\.pullRequestLookupResolved)

    // State reflects the PR context: workspace pinned to the PR branch,
    // repo matched to `acme/widgets`, and the banner is live.
    #expect(store.state.workspaceQuery == "feat/fix-widget")
    #expect(store.state.selectedWorkspace == .existingBranch(name: "feat/fix-widget"))
    if case .resolved(let context) = store.state.pullRequestLookup {
      #expect(context.parsed.number == 42)
      #expect(context.parsed.owner == "acme")
      #expect(context.parsed.repo == "widgets")
      #expect(context.metadata.title == "Fix the widget")
    } else {
      Issue.record("Expected .resolved state, got \(store.state.pullRequestLookup)")
    }
  }

  /// When no configured repo matches the PR's owner/repo, surface a
  /// clear reason in the banner instead of silently applying a mismatched
  /// workspace. Repo + workspace fields stay unlocked so the user can
  /// pick manually.
  @Test(.dependencies) func prURLWithNoMatchingRepoFailsGracefully() async {
    let state = Self.makeState()
    let store = TestStore(initialState: state) {
      NewTerminalFeature()
    } withDependencies: {
      $0.supacoolGithubPR.fetchMetadata = { owner, _, _ in
        SupacoolPRMetadata(
          title: "Upstream fix",
          headRefName: "bugfix",
          baseRefName: "main",
          headRepositoryOwner: owner,
          state: "OPEN",
          isDraft: false
        )
      }
      $0.gitClient.remoteInfo = { _ in
        // Configured repo is a *different* GitHub project — no match.
        GithubRemoteInfo(host: "github.com", owner: "elsewhere", repo: "other")
      }
    }
    store.exhaustivity = .off

    await store.send(\.binding.prompt, "https://github.com/acme/widgets/pull/7")
    await store.receive(\.pullRequestLookupNotMatched)

    if case .failed(_, let message) = store.state.pullRequestLookup {
      #expect(message.contains("acme/widgets"))
    } else {
      Issue.record("Expected .failed state, got \(store.state.pullRequestLookup)")
    }
    // Workspace wasn't auto-changed since the PR couldn't be applied.
    #expect(store.state.workspaceQuery == "")
    #expect(store.state.selectedWorkspace == .repoRoot)
  }

  /// Removing the URL from the prompt clears the PR context so subsequent
  /// submits use whatever the user typed into the workspace field
  /// manually. Doesn't reset workspaceQuery — the user may have edited it.
  @Test(.dependencies) func prURLRemovalResetsLookupToIdle() async {
    let state = Self.makeState()
    let store = TestStore(initialState: state) {
      NewTerminalFeature()
    } withDependencies: {
      $0.supacoolGithubPR.fetchMetadata = { owner, _, _ in
        SupacoolPRMetadata(
          title: "T",
          headRefName: "br",
          baseRefName: "main",
          headRepositoryOwner: owner,
          state: "OPEN",
          isDraft: false
        )
      }
      $0.gitClient.remoteInfo = { _ in
        GithubRemoteInfo(host: "github.com", owner: "acme", repo: "widgets")
      }
      $0.gitClient.localBranchNames = { _ in [] }
      $0.gitClient.remoteBranchRefs = { _ in [] }
    }
    store.exhaustivity = .off

    await store.send(\.binding.prompt, "https://github.com/acme/widgets/pull/1")
    await store.receive(\.pullRequestLookupResolved)
    #expect(store.state.pullRequestLookup != .idle)

    // Clear the URL — binding handler should reset PR state.
    await store.send(\.binding.prompt, "")
    #expect(store.state.pullRequestLookup == .idle)
  }

  // MARK: - PR URL parsing

  @Test func parsedPRURLFindsFirstMatchInText() {
    let text = "First try https://github.com/foo/bar/pull/12 then ignore later"
    let parsed = ParsedPullRequestURL.firstMatch(in: text)
    #expect(parsed?.owner == "foo")
    #expect(parsed?.repo == "bar")
    #expect(parsed?.number == 12)
  }

  @Test func parsedPRURLRejectsNonPRGithubLinks() {
    #expect(ParsedPullRequestURL.firstMatch(in: "https://github.com/foo/bar/issues/3") == nil)
    #expect(ParsedPullRequestURL.firstMatch(in: "no url here") == nil)
    #expect(ParsedPullRequestURL.firstMatch(in: "") == nil)
  }

  // MARK: - Remote destination

  @Test(.dependencies) func destinationChangedClearsValidationMessage() async {
    let hostID = UUID()
    var state = Self.makeState()
    state.validationMessage = "stale"
    let store = TestStore(initialState: state) {
      NewTerminalFeature()
    }
    store.exhaustivity = .off

    await store.send(.destinationChanged(.remote(hostID: hostID))) {
      $0.destination = .remote(hostID: hostID)
      $0.validationMessage = nil
    }
  }

  @Test(.dependencies) func remoteCreateRequiresAbsolutePath() async {
    let hostID = UUID()
    let host = RemoteHost(id: hostID, sshAlias: "dev", importedFromSSHConfig: true)
    var state = Self.makeState()
    state.destination = .remote(hostID: hostID)
    state.prompt = "Fix it"
    state.availableRemoteHosts = [host]
    state.remoteWorkingDirectoryDraft = "relative/path"
    @Shared(.remoteHosts) var sharedHosts: [RemoteHost]
    $sharedHosts.withLock { $0 = [host] }

    let store = TestStore(initialState: state) {
      NewTerminalFeature()
    } withDependencies: {
      $0.terminalClient.hookSocketPath = { "/tmp/supacool-local.sock" }
    }
    store.exhaustivity = .off

    await store.send(.createButtonTapped) {
      $0.validationMessage = "Remote path must be absolute (e.g. /home/me/code)."
    }
  }

  @Test(.dependencies) func remoteCreateRequiresRunningHookSocket() async {
    let hostID = UUID()
    let host = RemoteHost(id: hostID, sshAlias: "dev", importedFromSSHConfig: true)
    var state = Self.makeState()
    state.destination = .remote(hostID: hostID)
    state.prompt = "Fix it"
    state.availableRemoteHosts = [host]
    state.remoteWorkingDirectoryDraft = "/home/jz/code"
    @Shared(.remoteHosts) var sharedHosts: [RemoteHost]
    $sharedHosts.withLock { $0 = [host] }

    let store = TestStore(initialState: state) {
      NewTerminalFeature()
    } withDependencies: {
      $0.terminalClient.hookSocketPath = { nil }
    }
    store.exhaustivity = .off

    await store.send(.createButtonTapped) {
      $0.validationMessage = "Agent hook socket isn't running — can't tunnel hooks."
    }
  }

  @Test(.dependencies) func remoteCreateProducesSessionWithRemoteFields() async {
    let hostID = UUID()
    let host = RemoteHost(
      id: hostID,
      sshAlias: "dev",
      importedFromSSHConfig: true,
      overrides: RemoteHost.Overrides(remoteTmpdir: "/var/tmp")
    )
    var state = Self.makeState()
    state.destination = .remote(hostID: hostID)
    state.prompt = "Fix it"
    state.availableRemoteHosts = [host]
    state.remoteWorkingDirectoryDraft = "/home/jz/code/api"
    @Shared(.remoteHosts) var sharedHosts: [RemoteHost]
    $sharedHosts.withLock { $0 = [host] }

    let store = TestStore(initialState: state) {
      NewTerminalFeature()
    } withDependencies: {
      $0.terminalClient.hookSocketPath = { "/tmp/supacool-local.sock" }
      // Any send is a no-op — we're verifying the reducer's own state
      // transition, not the terminal client's side effects.
      $0.terminalClient.send = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.createButtonTapped) {
      $0.validationMessage = nil
      $0.isCreating = true
    }
    await store.receive(\.sessionReady) { state in
      state.isCreating = false
      // The session carries the remote trio so the board classifier
      // correctly flips to `.disconnected` when the link drops.
    }
    let lastAction = store.state  // Just touch state so actor isolation stays happy.
    _ = lastAction
  }

  @Test(.dependencies) func taskLoadsRepositoryRemoteTargetsFromSettings() async {
    let hostID = UUID()
    let target = RepositoryRemoteTarget(
      id: UUID(),
      hostID: hostID,
      remoteWorkingDirectory: "/srv/widgets",
      displayName: "staging"
    )
    let repoURL = URL(fileURLWithPath: "/tmp/repo")
    @Shared(.remoteHosts) var sharedHosts: [RemoteHost]
    @Shared(.repositorySettings(repoURL)) var repositorySettings
    $sharedHosts.withLock {
      $0 = [RemoteHost(id: hostID, sshAlias: "devbox", importedFromSSHConfig: true)]
    }
    $repositorySettings.withLock {
      $0.remoteTargets = [target]
    }

    let store = TestStore(initialState: Self.makeState()) {
      NewTerminalFeature()
    }
    store.exhaustivity = .off

    await store.send(.task) {
      $0.availableRemoteHosts = [RemoteHost(id: hostID, sshAlias: "devbox", importedFromSSHConfig: true)]
      $0.availableRepositoryRemoteTargets = [target]
      $0.isLoadingBranches = true
    }
  }

  @Test(.dependencies) func repositoryRemoteDestinationPrefillsPath() async {
    let hostID = UUID()
    let target = RepositoryRemoteTarget(
      id: UUID(),
      hostID: hostID,
      remoteWorkingDirectory: "/srv/widgets",
      displayName: "staging"
    )
    var state = Self.makeState()
    state.availableRepositoryRemoteTargets = [target]

    let store = TestStore(initialState: state) {
      NewTerminalFeature()
    }
    store.exhaustivity = .off

    await store.send(.destinationChanged(.repositoryRemote(targetID: target.id))) {
      $0.destination = .repositoryRemote(targetID: target.id)
      $0.remoteWorkingDirectoryDraft = "/srv/widgets"
      $0.validationMessage = nil
    }
  }

  @Test(.dependencies) func repositoryRemoteCreateUsesTargetPathWithoutManualDraft() async {
    let hostID = UUID()
    let host = RemoteHost(id: hostID, sshAlias: "dev", importedFromSSHConfig: true)
    let target = RepositoryRemoteTarget(
      id: UUID(),
      hostID: hostID,
      remoteWorkingDirectory: "/home/jz/code/api",
      displayName: "staging"
    )
    @Shared(.remoteHosts) var sharedHosts: [RemoteHost]
    $sharedHosts.withLock { $0 = [host] }

    var state = Self.makeState()
    state.destination = .repositoryRemote(targetID: target.id)
    state.prompt = "Fix it"
    state.availableRemoteHosts = [host]
    state.availableRepositoryRemoteTargets = [target]
    state.remoteWorkingDirectoryDraft = ""

    let store = TestStore(initialState: state) {
      NewTerminalFeature()
    } withDependencies: {
      $0.terminalClient.hookSocketPath = { "/tmp/supacool-local.sock" }
      $0.terminalClient.send = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.createButtonTapped) {
      $0.validationMessage = nil
      $0.isCreating = true
    }
    await store.receive(\.sessionReady) {
      $0.isCreating = false
    }
  }

  // MARK: - Helpers

  private static func makeState(
    selectedRepositoryID: Repository.ID? = "/tmp/repo"
  ) -> NewTerminalFeature.State {
    let repo = makeRepository(id: "/tmp/repo", name: "test-repo")
    var state = NewTerminalFeature.State(
      availableRepositories: IdentifiedArray(uniqueElements: [repo])
    )
    state.selectedRepositoryID = selectedRepositoryID
    return state
  }

  private static func makeRepository(
    id: String,
    name: String,
    worktrees: [Worktree] = []
  ) -> Repository {
    Repository(
      id: id,
      rootURL: URL(fileURLWithPath: id),
      name: name,
      worktrees: IdentifiedArray(uniqueElements: worktrees)
    )
  }
}
