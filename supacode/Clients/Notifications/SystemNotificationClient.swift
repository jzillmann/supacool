import AppKit
import ComposableArchitecture
import Foundation
import UserNotifications

/// `userInfo` key carrying the `AgentSession.ID` a notification is about, so a
/// click can deep-link to that session's full-screen terminal.
private let sessionIDUserInfoKey = "supacoolSessionID"

/// Click events flow out of the UN delegate through this stream; AppFeature
/// subscribes at launch (same pattern as `TerminalClient.events`). Created
/// eagerly so clicks that land before the subscription starts are buffered.
private nonisolated let sessionClickStream = AsyncStream.makeStream(of: UUID.self)

private final class ForegroundSystemNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    await Task.yield()
    return [.badge, .sound, .banner]
  }

  /// Clicking a notification should focus the app's existing main window, not
  /// let macOS's default activation spin up a fresh one. The app keeps running
  /// after its last window closes (`applicationShouldTerminateAfterLastWindowClosed`
  /// is false) and uses a single `Window` scene, so without this the default
  /// reopen path recreates a blank window instead of raising the live one.
  /// Mirrors `SupacoolAppDelegate.showMainWindow`.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse
  ) async {
    await Task.yield()
    if let raw = response.notification.request.content.userInfo[sessionIDUserInfoKey] as? String,
      let sessionID = UUID(uuidString: raw) {
      sessionClickStream.continuation.yield(sessionID)
    }
    let app = NSApplication.shared
    let window =
      app.windows.first { $0.identifier?.rawValue == WindowID.main }
      ?? app.windows.first { $0.identifier?.rawValue != WindowID.settings }
      ?? app.windows.first
    app.activate(ignoringOtherApps: true)
    if let window {
      if window.isMiniaturized { window.deminiaturize(nil) }
      window.makeKeyAndOrderFront(nil)
    }
  }
}

@MainActor
private let foregroundSystemNotificationDelegate = ForegroundSystemNotificationDelegate()

@MainActor
private func configuredNotificationCenter() -> UNUserNotificationCenter {
  let center = UNUserNotificationCenter.current()
  if center.delegate !== foregroundSystemNotificationDelegate {
    center.delegate = foregroundSystemNotificationDelegate
  }
  return center
}

struct SystemNotificationClient {
  struct AuthorizationRequestResult: Equatable {
    let granted: Bool
    let errorMessage: String?
  }

  enum AuthorizationStatus: Equatable {
    case authorized
    case denied
    case notDetermined
  }

  var authorizationStatus: @MainActor @Sendable () async -> AuthorizationStatus
  var requestAuthorization: @MainActor @Sendable () async -> AuthorizationRequestResult
  /// `sessionID` (when known) rides along in `userInfo` so a click on the
  /// notification can focus that session's terminal via `sessionClicks`.
  var send: @MainActor @Sendable (_ title: String, _ body: String, _ sessionID: UUID?) async -> Void
  var openSettings: @MainActor @Sendable () async -> Void
  /// Session IDs of clicked notifications that carried one.
  var sessionClicks: @Sendable () -> AsyncStream<UUID>
}

extension SystemNotificationClient: DependencyKey {
  static let liveValue = SystemNotificationClient(
    authorizationStatus: {
      let center = configuredNotificationCenter()
      let settings = await center.notificationSettings()
      switch settings.authorizationStatus {
      case .authorized, .provisional:
        return .authorized
      case .denied:
        return .denied
      case .notDetermined:
        return .notDetermined
      @unknown default:
        return .denied
      }
    },
    requestAuthorization: {
      let center = configuredNotificationCenter()
      do {
        let granted = try await center.requestAuthorization(
          options: [.alert, .badge, .sound]
        )
        return AuthorizationRequestResult(granted: granted, errorMessage: nil)
      } catch {
        return AuthorizationRequestResult(
          granted: false,
          errorMessage: error.localizedDescription
        )
      }
    },
    send: { title, body, sessionID in
      let center = configuredNotificationCenter()
      let content = UNMutableNotificationContent()
      content.title = title
      content.body = body
      content.sound = .default
      if let sessionID {
        content.userInfo[sessionIDUserInfoKey] = sessionID.uuidString
      }
      let request = UNNotificationRequest(
        identifier: UUID().uuidString,
        content: content,
        trigger: nil
      )
      try? await center.add(request)
    },
    openSettings: {
      guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") else {
        return
      }
      _ = NSWorkspace.shared.open(url)
    },
    sessionClicks: { sessionClickStream.stream }
  )

  static let testValue = SystemNotificationClient(
    authorizationStatus: { .notDetermined },
    requestAuthorization: { AuthorizationRequestResult(granted: false, errorMessage: nil) },
    send: { _, _, _ in },
    openSettings: {},
    sessionClicks: { AsyncStream { $0.finish() } }
  )
}

extension DependencyValues {
  var systemNotificationClient: SystemNotificationClient {
    get { self[SystemNotificationClient.self] }
    set { self[SystemNotificationClient.self] = newValue }
  }
}
