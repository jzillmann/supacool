import ComposableArchitecture
import ConcurrencyExtras
import DependenciesTestSupport
import Foundation
import Testing

@testable import Supacool

@MainActor
struct SettingsFeatureAgentHookTests {
  @Test(.dependencies) func agentHookCheckedSetsInstalled() async {
    var state = SettingsFeature.State()
    state.claudeProgressState = .checking

    let store = TestStore(initialState: state) {
      SettingsFeature()
    }

    await store.send(.agentHookChecked(.claudeProgress, installed: true)) {
      $0.claudeProgressState = .installed
    }
  }

  @Test(.dependencies) func agentHookCheckedSetsNotInstalled() async {
    var state = SettingsFeature.State()
    state.codexNotificationsState = .checking

    let store = TestStore(initialState: state) {
      SettingsFeature()
    }

    await store.send(.agentHookChecked(.codexNotifications, installed: false)) {
      $0.codexNotificationsState = .notInstalled
    }
  }

  @Test(.dependencies) func installTransitionsToInstalledOnSuccess() async {
    var state = SettingsFeature.State()
    state.claudeProgressState = .notInstalled

    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0[ClaudeSettingsClient.self].installProgress = {}
    }

    await store.send(.agentHookInstallTapped(.claudeProgress)) {
      $0.claudeProgressState = .installing
    }
    await store.receive(\.agentHookActionCompleted) {
      $0.claudeProgressState = .installed
    }
    // Success emits a delegate so BoardFeature can narrow / clear any
    // stale-hooks or failure card referencing this slot.
    await store.receive(\.delegate.hookInstallSucceeded)
  }

  @Test(.dependencies) func installTransitionsToFailedOnError() async {
    var state = SettingsFeature.State()
    state.codexProgressState = .notInstalled

    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0[CodexSettingsClient.self].installProgress = {
        throw CodexSettingsInstallerError.codexUnavailable
      }
    }

    await store.send(.agentHookInstallTapped(.codexProgress)) {
      $0.codexProgressState = .installing
    }
    await store.receive(\.agentHookActionCompleted) {
      $0.codexProgressState = .failed(CodexSettingsInstallerError.codexUnavailable.localizedDescription)
    }
    // Failure emits a delegate so BoardFeature can surface a red
    // "install failed" tray card.
    await store.receive(\.delegate.hookInstallFailed)
  }

  @Test(.dependencies) func installWhileLoadingIsNoOp() async {
    var state = SettingsFeature.State()
    state.claudeProgressState = .installing

    let store = TestStore(initialState: state) {
      SettingsFeature()
    }

    await store.send(.agentHookInstallTapped(.claudeProgress))
    // No state change, no effect — the guard short-circuits.
  }

  @Test(.dependencies) func uninstallTransitionsToNotInstalledOnSuccess() async {
    var state = SettingsFeature.State()
    state.claudeNotificationsState = .installed

    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0[ClaudeSettingsClient.self].uninstallNotifications = {}
    }

    await store.send(.agentHookUninstallTapped(.claudeNotifications)) {
      $0.claudeNotificationsState = .uninstalling
    }
    await store.receive(\.agentHookActionCompleted) {
      $0.claudeNotificationsState = .notInstalled
    }
  }

  @Test(.dependencies) func uninstallWhileLoadingIsNoOp() async {
    var state = SettingsFeature.State()
    state.codexNotificationsState = .checking

    let store = TestStore(initialState: state) {
      SettingsFeature()
    }

    await store.send(.agentHookUninstallTapped(.codexNotifications))
  }

  @Test(.dependencies) func taskStartsInstalledChecksInParallel() async {
    let startedChecks = LockIsolated<Set<String>>([])
    let continuations = LockIsolated<[CheckedContinuation<Void, Never>]>([])

    let store = TestStore(initialState: SettingsFeature.State()) {
      SettingsFeature()
    } withDependencies: {
      $0[ClaudeSettingsClient.self].checkInstalled = { progress in
        let key = progress ? "claudeProgress" : "claudeNotifications"
        _ = startedChecks.withValue { $0.insert(key) }
        await withCheckedContinuation { continuation in
          continuations.withValue { $0.append(continuation) }
        }
        return progress
      }
      $0[CodexSettingsClient.self].checkInstalled = { progress in
        let key = progress ? "codexProgress" : "codexNotifications"
        _ = startedChecks.withValue { $0.insert(key) }
        await withCheckedContinuation { continuation in
          continuations.withValue { $0.append(continuation) }
        }
        return progress
      }
      $0[PiSettingsClient.self].checkInstalled = {
        _ = startedChecks.withValue { $0.insert("piExtension") }
        await withCheckedContinuation { continuation in
          continuations.withValue { $0.append(continuation) }
        }
        return true
      }
    }

    await store.send(.task)
    await store.receive(\.settingsLoaded)
    await store.receive(\.delegate.settingsChanged)

    await eventually {
      startedChecks.value.count == 5
    }

    continuations.withValue { continuations in
      for continuation in continuations {
        continuation.resume()
      }
      continuations.removeAll()
    }

    await store.receive(\.agentHookChecked) {
      $0.claudeProgressState = .installed
    }
    await store.receive(\.agentHookChecked) {
      $0.claudeNotificationsState = .notInstalled
    }
    await store.receive(\.agentHookChecked) {
      $0.codexProgressState = .installed
    }
    await store.receive(\.agentHookChecked) {
      $0.codexNotificationsState = .notInstalled
    }
    await store.receive(\.agentHookChecked) {
      $0.piExtensionState = .installed
    }
  }

  @Test(.dependencies) func taskChecksAllFiveHookSlotsOnStartup() async {
    let checkedSlots = LockIsolated<[String]>([])

    let store = TestStore(initialState: SettingsFeature.State()) {
      SettingsFeature()
    } withDependencies: {
      $0[ClaudeSettingsClient.self].checkInstalled = { progress in
        checkedSlots.withValue { $0.append(progress ? "claudeProgress" : "claudeNotifications") }
        return progress
      }
      $0[CodexSettingsClient.self].checkInstalled = { progress in
        checkedSlots.withValue { $0.append(progress ? "codexProgress" : "codexNotifications") }
        return progress
      }
      $0[PiSettingsClient.self].checkInstalled = {
        checkedSlots.withValue { $0.append("piExtension") }
        return true
      }
    }

    await store.send(.task)
    await store.receive(\.settingsLoaded)
    await store.receive(\.delegate.settingsChanged)
    await store.receive(\.agentHookChecked) {
      $0.claudeProgressState = .installed
    }
    await store.receive(\.agentHookChecked) {
      $0.claudeNotificationsState = .notInstalled
    }
    await store.receive(\.agentHookChecked) {
      $0.codexProgressState = .installed
    }
    await store.receive(\.agentHookChecked) {
      $0.codexNotificationsState = .notInstalled
    }
    await store.receive(\.agentHookChecked) {
      $0.piExtensionState = .installed
    }

    #expect(
      Set(checkedSlots.value) == [
        "claudeProgress",
        "claudeNotifications",
        "codexProgress",
        "codexNotifications",
        "piExtension",
      ])
  }

  private func eventually(
    maxYields: Int = 100,
    _ predicate: () -> Bool
  ) async {
    for _ in 0..<maxYields {
      if predicate() { return }
      await Task.yield()
    }
    Issue.record("Condition was not satisfied before timeout")
  }
}
