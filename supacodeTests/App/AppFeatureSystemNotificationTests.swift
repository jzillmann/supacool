import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import SwiftUI
import Testing

@testable import Supacool

@MainActor
struct AppFeatureSystemNotificationTests {
  @Test(.dependencies) func firstTimeDeniedTurnsSystemNotificationsBackOffWithAlert() async {
    let storage = SettingsTestStorage()
    let authorizationRequests = LockIsolated(0)
    let store = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      TestStore(initialState: AppFeature.State()) {
        AppFeature()
      } withDependencies: {
        $0.systemNotificationClient.authorizationStatus = { .notDetermined }
        $0.systemNotificationClient.requestAuthorization = {
          authorizationRequests.withValue { $0 += 1 }
          return SystemNotificationClient.AuthorizationRequestResult(
            granted: false,
            errorMessage: "Mock request error"
          )
        }
      }
    }
    store.exhaustivity = .off

    await store.send(.settings(.binding(.set(\.systemNotificationsEnabled, true)))) {
      $0.settings.systemNotificationsEnabled = true
    }
    await store.receive(\.systemNotificationsPermissionFailed)
    await store.receive(\.settings.setSystemNotificationsEnabled) {
      $0.settings.systemNotificationsEnabled = false
    }
    let expectedAlert = AlertState<SettingsFeature.Alert> {
      TextState("Enable Notifications in System Settings")
    } actions: {
      ButtonState(action: .openSystemNotificationSettings) {
        TextState("Open System Settings")
      }
      ButtonState(role: .cancel, action: .dismiss) {
        TextState("Cancel")
      }
    } message: {
      TextState("Supacool cannot send system notifications.\n\nError: Mock request error")
    }
    await store.receive(\.settings.showNotificationPermissionAlert) {
      $0.settings.alert = expectedAlert
    }

    #expect(authorizationRequests.value == 1)
    #expect(store.state.settings.systemNotificationsEnabled == false)
    #expect(store.state.settings.alert == expectedAlert)
  }

  @Test(.dependencies) func deniedStatusShowsAlertAndOpensSystemSettings() async {
    let storage = SettingsTestStorage()
    let authorizationRequests = LockIsolated(0)
    let openedSettings = LockIsolated(0)
    let store = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      TestStore(initialState: AppFeature.State()) {
        AppFeature()
      } withDependencies: {
        $0.systemNotificationClient.authorizationStatus = { .denied }
        $0.systemNotificationClient.requestAuthorization = {
          authorizationRequests.withValue { $0 += 1 }
          return SystemNotificationClient.AuthorizationRequestResult(
            granted: false,
            errorMessage: "Mock request error"
          )
        }
        $0.systemNotificationClient.openSettings = {
          openedSettings.withValue { $0 += 1 }
        }
      }
    }
    store.exhaustivity = .off

    await store.send(.settings(.binding(.set(\.systemNotificationsEnabled, true)))) {
      $0.settings.systemNotificationsEnabled = true
    }
    await store.receive(\.systemNotificationsPermissionFailed)
    await store.receive(\.settings.setSystemNotificationsEnabled) {
      $0.settings.systemNotificationsEnabled = false
    }
    let expectedAlert = AlertState<SettingsFeature.Alert> {
      TextState("Enable Notifications in System Settings")
    } actions: {
      ButtonState(action: .openSystemNotificationSettings) {
        TextState("Open System Settings")
      }
      ButtonState(role: .cancel, action: .dismiss) {
        TextState("Cancel")
      }
    } message: {
      TextState("Supacool cannot send system notifications.\n\nError: Authorization status is denied.")
    }
    await store.receive(\.settings.showNotificationPermissionAlert) {
      $0.settings.alert = expectedAlert
    }

    #expect(authorizationRequests.value == 0)
    #expect(store.state.settings.systemNotificationsEnabled == false)
    #expect(store.state.settings.alert == expectedAlert)

    await store.send(.settings(.alert(.presented(.openSystemNotificationSettings)))) {
      $0.settings.alert = nil
    }
    await store.finish()
    #expect(openedSettings.value == 1)
  }

  @Test(.dependencies) func notificationReceivedSendsSystemNotificationWhenEnabled() async {
    var globalSettings = GlobalSettings.default
    globalSettings.systemNotificationsEnabled = true
    let session = Self.sampleSession(worktreeID: "/tmp/repo/wt-1")
    let sends = LockIsolated<[(String, String, UUID?)]>([])
    let initialState = AppFeature.State(
      settings: SettingsFeature.State(settings: globalSettings)
    )
    initialState.board.$sessions.withLock { $0 = [session] }
    let store = TestStore(initialState: initialState) {
      AppFeature()
    } withDependencies: {
      $0.systemNotificationClient.send = { title, body, sessionID in
        sends.withValue { $0.append((title, body, sessionID)) }
      }
    }
    store.exhaustivity = .off

    await store.send(
      .terminalEvent(
        .notificationReceived(
          worktreeID: "/tmp/repo/wt-1",
          title: "Done",
          body: "Build succeeded"
        )
      )
    )
    await store.finish()

    #expect(sends.value.count == 1)
    #expect(sends.value.first?.0 == "Done")
    #expect(sends.value.first?.1 == "Build succeeded")
    // The hook notification's worktree resolves to the board session, so a
    // click on it can deep-link back.
    #expect(sends.value.first?.2 == session.id)
  }

  @Test(.dependencies) func notificationReceivedSkipsLocalSoundWhenSystemNotificationsEnabled() async {
    var globalSettings = GlobalSettings.default
    globalSettings.systemNotificationsEnabled = true
    globalSettings.notificationSoundEnabled = true
    let plays = LockIsolated(0)
    let store = TestStore(
      initialState: AppFeature.State(
        settings: SettingsFeature.State(settings: globalSettings)
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.notificationSoundClient.play = {
        plays.withValue { $0 += 1 }
      }
    }
    store.exhaustivity = .off

    await store.send(
      .terminalEvent(
        .notificationReceived(
          worktreeID: "/tmp/repo/wt-1",
          title: "Done",
          body: "Build succeeded"
        )
      )
    )
    await store.finish()

    #expect(plays.value == 0)
  }

  @Test(.dependencies) func notificationReceivedPlaysLocalSoundWhenSystemNotificationsDisabled() async {
    var globalSettings = GlobalSettings.default
    globalSettings.systemNotificationsEnabled = false
    globalSettings.notificationSoundEnabled = true
    let plays = LockIsolated(0)
    let sends = LockIsolated(0)
    let store = TestStore(
      initialState: AppFeature.State(
        settings: SettingsFeature.State(settings: globalSettings)
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.notificationSoundClient.play = {
        plays.withValue { $0 += 1 }
      }
      $0.systemNotificationClient.send = { _, _, _ in
        sends.withValue { $0 += 1 }
      }
    }
    store.exhaustivity = .off

    await store.send(
      .terminalEvent(
        .notificationReceived(
          worktreeID: "/tmp/repo/wt-1",
          title: "Done",
          body: "Build succeeded"
        )
      )
    )
    await store.finish()

    #expect(plays.value == 1)
    #expect(sends.value == 0)
  }

  @Test(.dependencies) func priorityTerminationSendsSystemNotificationWhenBackgrounded() async {
    var globalSettings = GlobalSettings.default
    globalSettings.systemNotificationsEnabled = true
    let sessionID = UUID()
    let sends = LockIsolated<[(String, String, UUID?)]>([])
    var initialState = AppFeature.State(
      settings: SettingsFeature.State(settings: globalSettings)
    )
    initialState.scenePhase = .background
    let store = TestStore(initialState: initialState) {
      AppFeature()
    } withDependencies: {
      $0.systemNotificationClient.send = { title, body, sessionID in
        sends.withValue { $0.append((title, body, sessionID)) }
      }
    }
    store.exhaustivity = .off

    await store.send(
      .board(
        .delegate(
          .prioritySessionTerminated(
            sessionID: sessionID,
            title: "Priority session terminated",
            body: "Deploy fix finished and its terminal exited."
          )
        )
      )
    )
    await store.finish()

    #expect(sends.value.count == 1)
    #expect(sends.value.first?.0 == "Priority session terminated")
    #expect(sends.value.first?.1 == "Deploy fix finished and its terminal exited.")
    #expect(sends.value.first?.2 == sessionID)
  }

  @Test(.dependencies) func notificationClickFocusesSession() async {
    let session = Self.sampleSession(worktreeID: "/tmp/repo/wt-1")
    let initialState = AppFeature.State()
    initialState.board.$sessions.withLock { $0 = [session] }
    let store = TestStore(initialState: initialState) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.notificationSessionClicked(session.id))
    await store.receive(\.board.focusSession) {
      $0.board.focusedSessionID = session.id
    }
  }

  @Test(.dependencies) func notificationClickIgnoresUnknownSession() async {
    let initialState = AppFeature.State()
    let store = TestStore(initialState: initialState) {
      AppFeature()
    }

    // Session was removed between notification and click — no routing.
    await store.send(.notificationSessionClicked(UUID()))
  }

  private static func sampleSession(worktreeID: String) -> AgentSession {
    AgentSession(
      id: UUID(),
      repositoryID: "/tmp/repo",
      worktreeID: worktreeID,
      agent: .claude,
      initialPrompt: "Fix the failing tests"
    )
  }
}
