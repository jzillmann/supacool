import ComposableArchitecture
import Foundation

/// Installs Supacool's agy (Antigravity CLI) hooks as a plugin that Supacool
/// owns completely: `~/.gemini/config/plugins/supacool/`. agy discovers global
/// plugins there, so the user's own `hooks.json` is never touched.
///
/// Wiring (verified against agy 1.5.17):
/// - `PreInvocation` (before every model call) → busy on. `$PPID` is agy itself.
/// - `Stop` → busy off, plus the raw payload as a notification. agy sends
///   camelCase keys and no final message; `AgentHookSocketServer` maps
///   `conversationId` to the session id and reads the final message from
///   `transcriptPath`.
nonisolated struct AntigravityHooksInstaller {
  static let agentName = "antigravity"

  let homeDirectoryURL: URL
  let fileManager: FileManager

  init(
    homeDirectoryURL: URL = SupacoolPaths.spawnedProcessHomeDirectory,
    fileManager: FileManager = .default
  ) {
    self.homeDirectoryURL = homeDirectoryURL
    self.fileManager = fileManager
  }

  var pluginDirectory: URL {
    homeDirectoryURL.appending(path: ".gemini/config/plugins/supacool", directoryHint: .isDirectory)
  }

  /// Writes only the files whose content changed.
  func install() throws {
    try fileManager.createDirectory(at: pluginDirectory, withIntermediateDirectories: true)
    for (name, data) in try Self.files() {
      let url = pluginDirectory.appending(path: name, directoryHint: .notDirectory)
      guard fileManager.contents(atPath: url.path) != data else { continue }
      try data.write(to: url, options: .atomic)
    }
  }

  static func files() throws -> [String: Data] {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let busyOn = Handler(command: AgentHookSettingsCommand.busyCommand(active: true), timeout: 5)
    let busyOff = Handler(command: AgentHookSettingsCommand.busyCommand(active: false), timeout: 10)
    let notify = Handler(command: AgentHookSettingsCommand.notificationCommand(agent: agentName), timeout: 10)
    let hooks = ["supacool": ["PreInvocation": [busyOn], "Stop": [busyOff, notify]]]
    return [
      "plugin.json": try encoder.encode(["name": "supacool"]),
      "hooks.json": try encoder.encode(hooks),
    ]
  }

  private struct Handler: Encodable {
    let command: String
    let timeout: Int
  }
}

struct AntigravityHooksClient: Sendable {
  var install: @Sendable () async throws -> Void
}

extension AntigravityHooksClient: DependencyKey {
  static let liveValue = Self(install: { try AntigravityHooksInstaller().install() })
  static let testValue = Self(install: {})
}
