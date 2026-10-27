import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Testing

@testable import Supacool

/// ⌘N, the toolbar "+" and the full-screen "New Terminal" button used to pass
/// the view's repository list into the action. SwiftUI keeps the action
/// closure of a `.keyboardShortcut` button from its first render, so ⌘N kept
/// the launch-time list: no repository added later, and load order instead of
/// the Settings order. The sheet must read the list from state when it opens.
@MainActor
struct AppFeatureNewTerminalTests {
  private static func makeRepository(_ name: String) -> Repository {
    let root = "/tmp/\(name)"
    return Repository(
      id: root,
      rootURL: URL(fileURLWithPath: root),
      name: name,
      worktrees: []
    )
  }

  @Test(.dependencies) func newTerminalSheetListsRepositoriesAddedAfterLaunchInSettingsOrder() async {
    let first = Self.makeRepository("first")
    let second = Self.makeRepository("second")
    let addedLater = Self.makeRepository("added-later")
    // Load order is registration order; the Settings order puts the
    // repository added last in the middle.
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [first, second, addedLater]
    repositoriesState.repositoryRoots = [first, second, addedLater].map(\.rootURL)
    repositoriesState.repositoryOrderIDs = [second.id, addedLater.id, first.id]
    let store = TestStore(initialState: AppFeature.State(repositories: repositoriesState)) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.board(.newTerminalRequested))
    await store.receive(\.board.delegate.newTerminalRequested)
    await store.receive(\.board.openNewTerminalSheet)

    #expect(
      store.state.board.newTerminalSheet?.availableRepositories.map(\.id)
        == [second.id, addedLater.id, first.id]
    )
  }

  @Test(.dependencies) func repositoryReloadKeepsAnOpenSheetInSettingsOrder() async {
    let first = Self.makeRepository("first")
    let second = Self.makeRepository("second")
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [first, second]
    repositoriesState.repositoryRoots = [first, second].map(\.rootURL)
    repositoriesState.repositoryOrderIDs = [second.id, first.id]
    var initialState = AppFeature.State(repositories: repositoriesState)
    initialState.board.newTerminalSheet = NewTerminalFeature.State(
      availableRepositories: [first]
    )
    let store = TestStore(initialState: initialState) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { _ in }
      $0.worktreeInfoWatcher.send = { _ in }
    }
    store.exhaustivity = .off

    await store.send(
      .repositories(.delegate(.repositoriesChanged(repositoriesState.repositories)))
    )
    await store.receive(\.board._repositoriesUpdated)

    #expect(
      store.state.board.newTerminalSheet?.availableRepositories.map(\.id)
        == [second.id, first.id]
    )
  }
}
