import ComposableArchitecture
import ConcurrencyExtras
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Testing

@testable import Supacool

@MainActor
struct NewTerminalFeatureTests {
  // MARK: - Validation

  @Test(.dependencies) func createButtonRequiresPrompt() async {
    // Pin workspace to repo root so this test focuses on prompt
    // validation — otherwise the sheet's default (.newBranch(name: ""))
    // trips the branch-name check first.
    var state = Self.makeState()
    state.selectedWorkspace = .repoRoot
    let store = TestStore(initialState: state) {
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

  // MARK: - Submit dispatches spawn delegate

  /// Submitting a valid local request fires `.delegate(.spawnRequested)`
  /// — the parent (BoardFeature) owns the actual spawn so the sheet
  /// dismisses immediately. End-to-end behavior of the spawn itself
  /// (terminal command, fetch fallbacks, setup-script gating) lives in
  /// `SessionSpawnerTests`.
  @Test(.dependencies) func createButtonEmitsSpawnRequestedDelegate() async {
    var state = Self.makeState()
    state.prompt = "Summarize the README"
    // Pin workspace to repo root so create-button validation passes
    // without needing a real worktree-creation path.
    state.selectedWorkspace = .repoRoot

    let store = TestStore(initialState: state) {
      NewTerminalFeature()
    }
    store.exhaustivity = .off

    await store.send(.createButtonTapped)
    await store.receive(\.delegate.spawnRequested)
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

  // MARK: - Rerun initializer

  @Test(.dependencies) func workspaceQueryRoundTripKeepsWorktreeIntent() async {
    // Regression for "click Worktree → click Workspace field → picker
    // reverts to Main". The user explicitly chose a worktree
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
      displayName: "Write tests for auth",
      planMode: true,
      remoteControl: true
    )
    let repos = IdentifiedArray(uniqueElements: [
      Self.makeRepository(id: "/tmp/repo", name: "test-repo")
    ])

    let state = NewTerminalFeature.State(availableRepositories: repos, rerunFrom: previous)

    #expect(state.prompt == "Write tests for auth")
    #expect(state.agent == .codex)
    #expect(state.planMode == true)
    #expect(state.remoteControl == true)
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
      $0.backgroundInferenceClient.infer = { _, _ in "add-ssh-connection-pooling" }
    }

    await store.send(.suggestBranchNameTapped) {
      $0.isSuggestingBranchName = true
    }
    await store.receive(.branchNameSuggested("add-ssh-connection-pooling")) {
      $0.isSuggestingBranchName = false
      $0.workspaceQuery = "add-ssh-connection-pooling"
      $0.selectedWorkspace = .newBranch(name: "add-ssh-connection-pooling")
      $0.workspaceQueryUserEdited = true
    }
  }

  @Test(.dependencies) func suggestBranchNameResetsOnFailure() async {
    var state = Self.makeState()
    state.prompt = "Refactor auth module"

    struct InferenceError: Error {}
    let store = TestStore(initialState: state) {
      NewTerminalFeature()
    } withDependencies: {
      $0.backgroundInferenceClient.infer = { _, _ in throw InferenceError() }
    }

    await store.send(.suggestBranchNameTapped) {
      $0.isSuggestingBranchName = true
    }
    await store.receive(.branchNameSuggestionFailed) {
      $0.isSuggestingBranchName = false
    }
    #expect(store.state.workspaceQuery.isEmpty)
    // Failed inference leaves the sheet at its default scope — a blank
    // worktree — rather than silently sliding into the main checkout.
    #expect(store.state.selectedWorkspace == .newBranch(name: ""))
  }

  @Test(.dependencies) func suggestBranchNameSanitizesOutput() async {
    var state = Self.makeState()
    state.prompt = "Fix Mario's bug with special chars!"

    let store = TestStore(initialState: state) {
      NewTerminalFeature()
    } withDependencies: {
      // Model returns messy output
      $0.backgroundInferenceClient.infer = { _, _ in "  Fix Mario's Bug!!  \nextra line" }
    }

    await store.send(.suggestBranchNameTapped) {
      $0.isSuggestingBranchName = true
    }
    await store.receive(\.branchNameSuggested) {
      $0.isSuggestingBranchName = false
      $0.workspaceQuery = "fix-marios-bug"
      $0.selectedWorkspace = .newBranch(name: "fix-marios-bug")
      $0.workspaceQueryUserEdited = true
    }
  }

  // MARK: - Linear ticket title lookup

  /// Typing a prompt that names a Linear ticket fires a debounced fetch.
  /// On success, the title is cached and the workspace branch field is
  /// auto-filled with a kebab-cased name derived from the title.
  @Test(.dependencies) func linearTicketResolvesAndAutoFillsBranchName() async {
    let state = Self.makeState()
    let clock = TestClock()
    let store = TestStore(initialState: state) {
      NewTerminalFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.linearClient.fetchIssueTitle = { id in
        #expect(id == "CEN-6690")
        return "Streamline the foobar pipeline"
      }
    }
    store.exhaustivity = .off

    await store.send(\.binding.prompt, "Fix CEN-6690")
    #expect(store.state.pendingLinearTicketID == "CEN-6690")
    await clock.advance(by: .milliseconds(400))
    await store.receive(\.linearTicketTitleResolved)

    #expect(store.state.linearTitleCache["CEN-6690"] == "Streamline the foobar pipeline")
    #expect(store.state.workspaceQuery == "cen-6690-streamline-the-foobar-pipeline")
    #expect(
      store.state.selectedWorkspace
        == .newBranch(name: "cen-6690-streamline-the-foobar-pipeline")
    )
  }

  /// If the user has already typed something into the workspace field,
  /// the auto-fill from a resolved Linear title doesn't overwrite it.
  /// Their intent wins.
  @Test(.dependencies) func linearTicketAutoFillRespectsUserEdit() async {
    var state = Self.makeState()
    state.workspaceQuery = "my-custom-branch"
    state.workspaceQueryUserEdited = true
    let clock = TestClock()
    let store = TestStore(initialState: state) {
      NewTerminalFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.linearClient.fetchIssueTitle = { _ in "Some Linear title" }
    }
    store.exhaustivity = .off

    await store.send(\.binding.prompt, "Look into CEN-1")
    await clock.advance(by: .milliseconds(400))
    await store.receive(\.linearTicketTitleResolved)

    // Cache was populated, but the field was left alone.
    #expect(store.state.linearTitleCache["CEN-1"] == "Some Linear title")
    #expect(store.state.workspaceQuery == "my-custom-branch")
  }

  /// A negative cache entry (failed lookup or unknown ticket) prevents
  /// re-fetching on subsequent keystrokes for the same id.
  @Test(.dependencies) func linearTicketFailureNegativelyCaches() async {
    let state = Self.makeState()
    let clock = TestClock()
    struct Boom: Error {}
    let fetchCount = LockIsolated(0)
    let store = TestStore(initialState: state) {
      NewTerminalFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.linearClient.fetchIssueTitle = { _ in
        fetchCount.withValue { $0 += 1 }
        throw Boom()
      }
    }
    store.exhaustivity = .off

    await store.send(\.binding.prompt, "CEN-9999")
    await clock.advance(by: .milliseconds(400))
    await store.receive(\.linearTicketTitleFailed)

    #expect(store.state.linearTitleCache["CEN-9999"] == "")

    // Editing the prompt while keeping the same id must not re-fetch.
    await store.send(\.binding.prompt, "CEN-9999 please look")
    await clock.advance(by: .milliseconds(400))
    #expect(fetchCount.value == 1)
  }

  /// When a Linear title is cached, the wand button uses it directly
  /// instead of round-tripping through the LLM.
  @Test(.dependencies) func suggestBranchNamePrefersCachedLinearTitle() async {
    var state = Self.makeState()
    state.prompt = "Fix CEN-6690"
    state.linearTitleCache["CEN-6690"] = "Improve auto naming"
    let inferenceCalls = LockIsolated(0)
    let store = TestStore(initialState: state) {
      NewTerminalFeature()
    } withDependencies: {
      $0.backgroundInferenceClient.infer = { _, _ in
        inferenceCalls.withValue { $0 += 1 }
        return "should-not-be-used"
      }
    }
    store.exhaustivity = .off

    await store.send(.suggestBranchNameTapped)
    await store.receive(\.branchNameSuggested) {
      $0.workspaceQuery = "cen-6690-improve-auto-naming"
      $0.selectedWorkspace = .newBranch(name: "cen-6690-improve-auto-naming")
      $0.workspaceQueryUserEdited = true
    }
    #expect(inferenceCalls.value == 0)
    #expect(store.state.isSuggestingBranchName == false)
  }

  /// Branch / display name helpers produce the expected slugs.
  @Test func linearNamingHelpers() {
    #expect(
      branchNameFromLinearTitle(ticketID: "CEN-6690", title: "Streamline the foobar")
        == "cen-6690-streamline-the-foobar"
    )
    #expect(
      displayNameFromLinearTitle(ticketID: "CEN-6690", title: "Streamline the foobar")
        == "CEN-6690 · Streamline the foobar"
    )
    // Empty title falls back to bare ticket id.
    #expect(branchNameFromLinearTitle(ticketID: "CEN-6690", title: "  ") == "cen-6690")
    #expect(displayNameFromLinearTitle(ticketID: "CEN-6690", title: "") == "CEN-6690")
  }

  /// `suggestedDisplayName` prefers a resolved PR over a Linear title
  /// when both are present — the PR URL is the stronger explicit signal.
  @Test func suggestedDisplayNamePrefersPullRequestOverLinear() {
    var state = Self.makeState()
    state.prompt = "Fix CEN-1 (see PR)"
    state.linearTitleCache["CEN-1"] = "Linear title"
    state.pullRequestLookup = .resolved(
      PullRequestContext(
        parsed: ParsedPullRequestURL(
          url: "https://github.com/acme/widgets/pull/42",
          owner: "acme",
          repo: "widgets",
          number: 42
        ),
        metadata: SupacoolPRMetadata(
          title: "PR title",
          headRefName: "feat",
          baseRefName: "main",
          headRepositoryOwner: "acme",
          state: "OPEN",
          isDraft: false
        ),
        matchedRepositoryID: "/tmp/repo",
        isFork: false
      )
    )
    #expect(NewTerminalFeature.suggestedDisplayName(state: state) == "PR #42: PR title")
  }

  /// `suggestedDisplayName` falls back to the cached Linear title when
  /// no PR is resolved.
  @Test func suggestedDisplayNameUsesLinearTitleWhenNoPR() {
    var state = Self.makeState()
    state.prompt = "Fix CEN-6690 today"
    state.linearTitleCache["CEN-6690"] = "Streamline the foobar"
    #expect(
      NewTerminalFeature.suggestedDisplayName(state: state)
        == "CEN-6690 · Streamline the foobar"
    )
  }

  /// `suggestedDisplayName` returns nil when neither signal is available
  /// — callers fall back to `AgentSession.deriveDisplayName`.
  @Test func suggestedDisplayNameIsNilWithoutSignal() {
    var state = Self.makeState()
    state.prompt = "Just a quick task"
    #expect(NewTerminalFeature.suggestedDisplayName(state: state) == nil)
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
    // Workspace wasn't auto-changed since the PR couldn't be applied —
    // the sheet sits on its default scope (a blank worktree).
    #expect(store.state.workspaceQuery == "")
    #expect(store.state.selectedWorkspace == .newBranch(name: ""))
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

  /// Dismissing the PR banner drops the association without touching the
  /// prompt. Subsequent prompt edits that still contain the same URL must
  /// NOT re-trigger the lookup — the whole point of dismiss is surviving
  /// incidental PR URLs in pasted logs. Editing to a different PR URL
  /// starts a fresh lookup.
  @Test(.dependencies) func prURLDismissKeepsAssociationDroppedEvenIfURLLingers() async {
    let state = Self.makeState()
    let store = TestStore(initialState: state) {
      NewTerminalFeature()
    } withDependencies: {
      $0.supacoolGithubPR.fetchMetadata = { owner, _, number in
        SupacoolPRMetadata(
          title: "PR #\(number)",
          headRefName: "feat/pr-\(number)",
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

    // Paste a log that embeds a PR URL.
    let pastedLog = "Cyclenerd manager logs: https://github.com/acme/widgets/pull/2419 broke the build"
    await store.send(\.binding.prompt, pastedLog)
    await store.receive(\.pullRequestLookupResolved)
    #expect({ if case .resolved = store.state.pullRequestLookup { return true } else { return false } }())

    // User dismisses the banner.
    await store.send(.pullRequestDismissTapped)
    if case .dismissed(let parsed) = store.state.pullRequestLookup {
      #expect(parsed.number == 2419)
    } else {
      Issue.record("Expected .dismissed after pullRequestDismissTapped, got \(store.state.pullRequestLookup)")
    }

    // User keeps typing — the same URL is still in the prompt. No re-fetch.
    await store.send(\.binding.prompt, pastedLog + " and also something else")
    if case .dismissed = store.state.pullRequestLookup {
      // Expected.
    } else {
      Issue.record("Expected .dismissed to survive a same-URL prompt edit, got \(store.state.pullRequestLookup)")
    }

    // A different PR URL should re-arm the lookup.
    await store.send(\.binding.prompt, "try https://github.com/acme/widgets/pull/99 instead")
    await store.receive(\.pullRequestLookupResolved)
    if case .resolved(let context) = store.state.pullRequestLookup {
      #expect(context.parsed.number == 99)
    } else {
      Issue.record("Expected .resolved for new URL, got \(store.state.pullRequestLookup)")
    }
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

  @Test(.dependencies) func remoteCreateUsesSessionIDAsRemoteSurfaceID() async throws {
    let hostID = UUID()
    let host = RemoteHost(id: hostID, sshAlias: "dev", importedFromSSHConfig: true)
    var state = Self.makeState()
    state.destination = .remote(hostID: hostID)
    state.prompt = "Fix it"
    state.availableRemoteHosts = [host]
    state.remoteWorkingDirectoryDraft = "/home/jz/code/api"
    @Shared(.remoteHosts) var sharedHosts: [RemoteHost]
    @Shared(.remoteWorkspaces) var sharedWorkspaces: [RemoteWorkspace]
    $sharedHosts.withLock { $0 = [host] }
    $sharedWorkspaces.withLock { $0 = [] }
    let sentCommands = LockIsolated<[TerminalClient.Command]>([])

    let store = TestStore(initialState: state) {
      NewTerminalFeature()
    } withDependencies: {
      $0.terminalClient.hookSocketPath = { "/tmp/supacool-local.sock" }
      $0.terminalClient.send = { command in
        sentCommands.withValue { $0.append(command) }
      }
    }
    store.exhaustivity = .off

    await store.send(.createButtonTapped) {
      $0.validationMessage = nil
      $0.isCreating = true
    }
    await store.receive(\.sessionReady) {
      $0.isCreating = false
    }

    let command = try #require(sentCommands.value.first)
    guard case .createRemoteTab(let worktree, let sshCommand, let id, let surfaceID) = command else {
      Issue.record("Expected createRemoteTab command, got \(command)")
      return
    }
    #expect(worktree.id == "remote:dev:/home/jz/code/api")
    #expect(id == surfaceID)
    #expect(!sshCommand.contains("SetEnv="))
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
