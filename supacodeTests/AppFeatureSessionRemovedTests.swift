import ComposableArchitecture
import ConcurrencyExtras
import DependenciesTestSupport
import Foundation
import Testing

@testable import Supacool

/// Regressions for the `.board(.delegate(.sessionRemoved))` handler in
/// `AppFeature` — specifically that it always tears down the PTY tab,
/// even when the underlying `Repository`/`Worktree` records have been
/// pruned. A previous revision short-circuited `destroyTab` whenever
/// `resolveBoardSessionWorktree` returned nil, leaking the PTY (and the
/// agent process inside it) for every session removed after its repo
/// was unregistered.
@MainActor
struct AppFeatureSessionRemovedTests {
  @Test(.dependencies) func sessionRemovedDestroysTabEvenWhenRepoMissing() async {
    // Repositories.state intentionally empty — simulates "session was
    // removed after the repo was unregistered" or "worktree state
    // pruned mid-flight".
    let sessionID = UUID()
    let repositoryID = "/tmp/missing-repo"
    let worktreeID = "/tmp/missing-repo/wt-x"

    let sentCommands = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(
      initialState: AppFeature.State(repositories: RepositoriesFeature.State())
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sentCommands.withValue { $0.append(command) }
      }
    }
    store.exhaustivity = .off

    await store.send(
      .board(
        .delegate(
          .sessionRemoved(
            sessionID: sessionID,
            repositoryID: repositoryID,
            worktreeID: worktreeID,
            deleteBackingWorktree: false,
            additionalWorktreeIDsToDelete: []
          )
        )
      )
    )
    // Give the .run effect a tick to land.
    await Task.yield()
    await Task.yield()

    let sawDestroy = sentCommands.value.contains { command in
      if case .destroyTab(let worktree, let tabID) = command {
        return worktree.id == worktreeID
          && tabID == TerminalTabID(rawValue: sessionID)
      }
      return false
    }
    #expect(sawDestroy, "destroyTab must fire even when the repo is no longer registered")
  }

  @Test(.dependencies) func sessionRemovedDestroysTabWhenRepoPresent() async {
    // Sanity: the happy path still works. Repo registered → destroyTab
    // fires with the resolved Worktree (not the shim).
    let worktree = Worktree(
      id: "/tmp/repo/wt-x",
      name: "wt-x",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-x"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
    let repository = Repository(
      id: "/tmp/repo",
      rootURL: URL(fileURLWithPath: "/tmp/repo"),
      name: "repo",
      worktrees: [worktree]
    )
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    let sessionID = UUID()

    let sentCommands = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(
      initialState: AppFeature.State(repositories: repositoriesState)
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sentCommands.withValue { $0.append(command) }
      }
    }
    store.exhaustivity = .off

    await store.send(
      .board(
        .delegate(
          .sessionRemoved(
            sessionID: sessionID,
            repositoryID: repository.id,
            worktreeID: worktree.id,
            deleteBackingWorktree: false,
            additionalWorktreeIDsToDelete: []
          )
        )
      )
    )
    await Task.yield()
    await Task.yield()

    let sawDestroy = sentCommands.value.contains { command in
      if case .destroyTab(let resolved, _) = command {
        return resolved.id == worktree.id
      }
      return false
    }
    #expect(sawDestroy)
  }
}
