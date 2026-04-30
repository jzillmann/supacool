import ComposableArchitecture
import Foundation

struct PiSettingsClient: Sendable {
  var checkInstalled: @Sendable () async -> Bool
  var checkInstallState: @Sendable () async -> AgentHookSettingsFileInstaller.InstallState
  var install: @Sendable () async throws -> Void
  var uninstall: @Sendable () async throws -> Void
}

extension PiSettingsClient: DependencyKey {
  static let liveValue = Self(
    checkInstalled: {
      PiSettingsInstaller().isInstalled()
    },
    checkInstallState: {
      PiSettingsInstaller().installState()
    },
    install: {
      try PiSettingsInstaller().install()
    },
    uninstall: {
      try PiSettingsInstaller().uninstall()
    }
  )

  static let testValue = Self(
    checkInstalled: { false },
    checkInstallState: { .missing },
    install: {},
    uninstall: {}
  )
}

extension DependencyValues {
  var piSettingsClient: PiSettingsClient {
    get { self[PiSettingsClient.self] }
    set { self[PiSettingsClient.self] = newValue }
  }
}
