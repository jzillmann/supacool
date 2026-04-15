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

  @Test(.dependencies) func worktreeModeRequiresBranchName() async {
    var state = Self.makeState()
    state.prompt = "Explore the codebase"
    state.worktreeMode = .newBranch

    let store = TestStore(initialState: state) {
      NewTerminalFeature()
    }
    store.exhaustivity = .off

    await store.send(.createButtonTapped) {
      $0.validationMessage = "Branch name required."
    }
  }

  @Test(.dependencies) func worktreeModeRejectsBranchWithWhitespace() async {
    var state = Self.makeState()
    state.prompt = "Explore"
    state.worktreeMode = .newBranch
    state.branchName = "feat with spaces"

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
    #expect(spawnedInput == "claude 'Summarize the README'\r")
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

    #expect(spawnedInput.value == "codex 'List the tests'\r")
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
    state.worktreeMode = .newBranch
    state.branchName = "feat/x"

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
    state.worktreeMode = .newBranch
    state.branchName = "feat/x"

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
    state.worktreeMode = .newBranch
    state.branchName = "feat/x"

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
    #expect(state.worktreeMode == .none)
    #expect(state.branchName.isEmpty)
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
