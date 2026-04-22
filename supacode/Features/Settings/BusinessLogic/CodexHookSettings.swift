import Foundation

nonisolated enum CodexHookSettings {
  fileprivate static let busyOn = AgentHookSettingsCommand.busyCommand(active: true)
  fileprivate static let busyOff = AgentHookSettingsCommand.busyCommand(active: false)
  fileprivate static let notify = AgentHookSettingsCommand.notificationCommand(agent: "codex")

  static func progressHookGroupsByEvent() throws -> [String: [JSONValue]] {
    try AgentHookPayloadSupport.extractHookGroups(
      from: CodexProgressPayload(),
      invalidConfiguration: CodexHookSettingsError.invalidConfiguration
    )
  }

  static func notificationHookGroupsByEvent() throws -> [String: [JSONValue]] {
    try AgentHookPayloadSupport.extractHookGroups(
      from: CodexNotificationPayload(),
      invalidConfiguration: CodexHookSettingsError.invalidConfiguration
    )
  }
}

nonisolated enum CodexHookSettingsError: Error {
  case invalidConfiguration
}

// MARK: - Progress hooks.

// UserPromptSubmit/PreToolUse flip busy on; Stop flips it off. PreToolUse
// mirrors Claude's fix — without it, awaiting-input lingers after Codex
// resumes from a PermissionRequest until the 8s TTL / screen poll clears
// it. Codex currently only emits PreToolUse for the Bash tool; the matcher
// is explicit so non-Bash tool events (once they land) don't flip busy
// without further audit.
private nonisolated struct CodexProgressPayload: Encodable {
  let hooks: [String: [AgentHookGroup]] = [
    "UserPromptSubmit": [
      .init(hooks: [
        .init(command: CodexHookSettings.busyOn, timeout: 10)
      ]),
    ],
    "PreToolUse": [
      .init(matcher: "Bash", hooks: [.init(command: CodexHookSettings.busyOn, timeout: 5)])
    ],
    "Stop": [
      .init(hooks: [.init(command: CodexHookSettings.busyOff, timeout: 10)])
    ],
  ]
}

// MARK: - Notification hooks.

// Stop forwards the final assistant message; PermissionRequest is Codex's
// equivalent of Claude's "needs your permission" Notification — the only
// way Supacool can tell that a Codex card is blocked on user approval
// rather than still running.
private nonisolated struct CodexNotificationPayload: Encodable {
  let hooks: [String: [AgentHookGroup]] = [
    "Stop": [
      .init(hooks: [.init(command: CodexHookSettings.notify, timeout: 10)])
    ],
    "PermissionRequest": [
      .init(matcher: "", hooks: [.init(command: CodexHookSettings.notify, timeout: 10)])
    ],
  ]
}
