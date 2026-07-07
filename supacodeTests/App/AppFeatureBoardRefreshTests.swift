import ComposableArchitecture
import ConcurrencyExtras
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Testing

@testable import Supacool

@MainActor
struct AppFeatureBoardRefreshTests {
  @Test(.dependencies) func boardRefreshWorktreeAlsoRefreshesPullRequestState() async {
    let repoRoot = "/tmp/repo"
    let featureWorktree = Worktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "\(repoRoot)/feature"),
      repositoryRootURL: URL(fileURLWithPath: repoRoot)
    )
    let repository = Repository(
      id: repoRoot,
      rootURL: URL(fileURLWithPath: repoRoot),
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [featureWorktree])
    )
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.githubIntegrationAvailability = .available
    let requestedBranches = LockIsolated<[[String]]>([])
    let store = TestStore(
      initialState: AppFeature.State(repositories: repositoriesState)
    ) {
      AppFeature()
    } withDependencies: {
      $0.gitClient.branchName = { _ in nil }
      $0.gitClient.lineChanges = { _ in nil }
      $0.gitClient.remoteInfo = { _ in
        GithubRemoteInfo(host: "github.com", owner: "acme", repo: "repo")
      }
      $0.githubCLI.batchPullRequests = { _, _, _, branches in
        requestedBranches.withValue { $0.append(branches) }
        return [:]
      }
    }
    store.exhaustivity = .off

    await store.send(
      .board(.delegate(.refreshWorktreeRequested(worktreeID: featureWorktree.id)))
    )
    await store.skipReceivedActions()
    await store.finish()

    #expect(requestedBranches.value == [["feature"]])
  }
}
