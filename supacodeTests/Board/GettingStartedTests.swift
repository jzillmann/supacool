import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import Supacool

@MainActor
struct GettingStartedTests {
  // MARK: - Evaluator

  @Test func evaluator_noRepo_noHooks_noHosts_surfacesAllThree() {
    let pending = GettingStartedEvaluator.pending(
      hasRepositories: false,
      hasAllHooksInstalled: false,
      hasRemoteHosts: false,
      skipped: []
    )
    #expect(pending == [.setupRepo, .installHooks, .setupRemoteHost])
  }

  @Test func evaluator_repoAdded_dropsSetupRepoCard() {
    let pending = GettingStartedEvaluator.pending(
      hasRepositories: true,
      hasAllHooksInstalled: false,
      hasRemoteHosts: false,
      skipped: []
    )
    #expect(pending == [.installHooks, .setupRemoteHost])
  }

  @Test func evaluator_everythingDone_returnsEmpty() {
    let pending = GettingStartedEvaluator.pending(
      hasRepositories: true,
      hasAllHooksInstalled: true,
      hasRemoteHosts: true,
      skipped: []
    )
    #expect(pending.isEmpty)
  }

  @Test func evaluator_skippedTasksFilteredOut() {
    let pending = GettingStartedEvaluator.pending(
      hasRepositories: false,
      hasAllHooksInstalled: false,
      hasRemoteHosts: false,
      skipped: [GettingStartedTask.installHooks.rawValue]
    )
    // installHooks is incomplete but skipped — carousel skips it.
    #expect(pending == [.setupRepo, .setupRemoteHost])
  }

  @Test func evaluator_allSkipped_returnsEmpty() {
    let skipped = Set(GettingStartedTask.allCases.map(\.rawValue))
    let pending = GettingStartedEvaluator.pending(
      hasRepositories: false,
      hasAllHooksInstalled: false,
      hasRemoteHosts: false,
      skipped: skipped
    )
    #expect(pending.isEmpty)
  }

  // MARK: - Reducer: evaluated

  @Test(.dependencies) func evaluatedWithPendingPresentsCarousel() async {
    Self.clearSkipStorage()
    let store = TestStore(initialState: BoardFeature.State()) {
      BoardFeature()
    }
    await store.send(
      .gettingStartedEvaluated(pending: [.setupRepo, .installHooks])
    ) {
      $0.gettingStarted.tasks = [.setupRepo, .installHooks]
      $0.gettingStarted.isPresented = true
      $0.gettingStarted.currentIndex = 0
    }
  }

  @Test(.dependencies) func evaluatedWithEmptyPendingHidesCarousel() async {
    Self.clearSkipStorage()
    var state = BoardFeature.State()
    state.gettingStarted.isPresented = true
    state.gettingStarted.tasks = [.setupRepo]
    state.gettingStarted.currentIndex = 0
    let store = TestStore(initialState: state) {
      BoardFeature()
    }
    await store.send(.gettingStartedEvaluated(pending: [])) {
      $0.gettingStarted.tasks = []
      $0.gettingStarted.isPresented = false
      $0.gettingStarted.currentIndex = 0
    }
  }

  @Test(.dependencies) func evaluatedClampsCurrentIndexToRemainingTasks() async {
    Self.clearSkipStorage()
    var state = BoardFeature.State()
    state.gettingStarted.isPresented = true
    state.gettingStarted.tasks = [.setupRepo, .installHooks, .setupRemoteHost]
    state.gettingStarted.currentIndex = 2
    let store = TestStore(initialState: state) {
      BoardFeature()
    }
    // One task removed — index 2 is now out of range; reducer clamps.
    await store.send(
      .gettingStartedEvaluated(pending: [.setupRepo, .installHooks])
    ) {
      $0.gettingStarted.tasks = [.setupRepo, .installHooks]
      $0.gettingStarted.currentIndex = 1
    }
  }

  // MARK: - Reducer: skip

  @Test(.dependencies) func skipTaskPersistsAndRemovesFromList() async {
    Self.clearSkipStorage()
    var state = BoardFeature.State()
    state.gettingStarted.isPresented = true
    state.gettingStarted.tasks = [.setupRepo, .installHooks]
    let store = TestStore(initialState: state) {
      BoardFeature()
    }
    await store.send(.gettingStartedSkipTapped(.setupRepo)) {
      $0.$skippedGettingStartedTasks.withLock { raw in
        raw = [GettingStartedTask.setupRepo.rawValue]
      }
      $0.gettingStarted.tasks = [.installHooks]
      $0.gettingStarted.currentIndex = 0
    }
  }

  @Test(.dependencies) func skipLastTaskHidesCarousel() async {
    Self.clearSkipStorage()
    var state = BoardFeature.State()
    state.gettingStarted.isPresented = true
    state.gettingStarted.tasks = [.setupRemoteHost]
    let store = TestStore(initialState: state) {
      BoardFeature()
    }
    await store.send(.gettingStartedSkipTapped(.setupRemoteHost)) {
      $0.$skippedGettingStartedTasks.withLock { raw in
        raw = [GettingStartedTask.setupRemoteHost.rawValue]
      }
      $0.gettingStarted.tasks = []
      $0.gettingStarted.isPresented = false
      $0.gettingStarted.currentIndex = 0
    }
  }

  // MARK: - Reducer: dismiss + show again

  @Test(.dependencies) func dismissHidesCarouselButKeepsTasks() async {
    Self.clearSkipStorage()
    var state = BoardFeature.State()
    state.gettingStarted.isPresented = true
    state.gettingStarted.tasks = [.setupRepo]
    let store = TestStore(initialState: state) {
      BoardFeature()
    }
    await store.send(.gettingStartedDismiss) {
      $0.gettingStarted.isPresented = false
    }
  }

  @Test(.dependencies) func showAgainClearsSkipAndRequestsReevaluation() async {
    Self.clearSkipStorage()
    var state = BoardFeature.State()
    state.$skippedGettingStartedTasks.withLock { raw in
      raw = [GettingStartedTask.installHooks.rawValue]
    }
    let store = TestStore(initialState: state) {
      BoardFeature()
    }
    await store.send(.gettingStartedShowAgain) {
      $0.$skippedGettingStartedTasks.withLock { $0 = [] }
    }
    await store.receive(\.delegate.gettingStartedReevaluateRequested)
  }

  // MARK: - Reducer: setup + navigation

  @Test(.dependencies) func setupTappedEmitsDelegate() async {
    Self.clearSkipStorage()
    var state = BoardFeature.State()
    state.gettingStarted.isPresented = true
    state.gettingStarted.tasks = [.installHooks]
    let store = TestStore(initialState: state) {
      BoardFeature()
    }
    await store.send(.gettingStartedSetupTapped(.installHooks))
    await store.receive(\.delegate.gettingStartedSetupRequested)
  }

  @Test(.dependencies) func setCurrentIndexClampsToTaskCount() async {
    Self.clearSkipStorage()
    var state = BoardFeature.State()
    state.gettingStarted.tasks = [.setupRepo, .installHooks]
    state.gettingStarted.currentIndex = 0
    let store = TestStore(initialState: state) {
      BoardFeature()
    }
    await store.send(.gettingStartedSetCurrentIndex(99)) {
      $0.gettingStarted.currentIndex = 1
    }
  }

  // MARK: - Helpers

  /// Clear persisted skip state between tests. `@Shared(.appStorage(...))`
  /// uses `UserDefaults.standard`, which is shared across the test process,
  /// so without this hop a skip from one test leaks into the next.
  private static func clearSkipStorage() {
    UserDefaults.standard.removeObject(forKey: "gettingStartedSkippedTasks")
  }
}
