import Foundation

nonisolated enum ClaudeHookSettings {
  fileprivate static let busyOn = AgentHookSettingsCommand.busyCommand(active: true)
  fileprivate static let busyOff = AgentHookSettingsCommand.busyCommand(active: false)
  fileprivate static let notify = AgentHookSettingsCommand.notificationCommand(agent: "claude")

  static func progressHookGroupsByEvent() throws -> [String: [JSONValue]] {
    try AgentHookPayloadSupport.extractHookGroups(
      from: ClaudeProgressPayload(),
      invalidConfiguration: ClaudeHookSettingsError.invalidConfiguration
    )
  }

  static func notificationHookGroupsByEvent() throws -> [String: [JSONValue]] {
    try AgentHookPayloadSupport.extractHookGroups(
      from: ClaudeNotificationPayload(),
      invalidConfiguration: ClaudeHookSettingsError.invalidConfiguration
    )
  }
}

nonisolated enum ClaudeHookSettingsError: Error {
  case invalidConfiguration
}

// MARK: - Progress hooks.

// UserPromptSubmit/PreToolUse sets busy, Stop/SessionEnd/PostToolUseFailure clears it.
// PreToolUse is the only hook that fires when Claude resumes after a permission
// grant — without it "Wants Input" lingers until the screen-fingerprint poll or
// the 8s TTL clears it. The socket send is a ~30-byte echo through nc -U -w1,
// so the 5s timeout is ample even under load.
private nonisolated struct ClaudeProgressPayload: Encodable {
  let hooks: [String: [AgentHookGroup]] = [
    "UserPromptSubmit": [
      .init(hooks: [
        .init(command: ClaudeHookSettings.busyOn, timeout: 10)
      ]),
    ],
    "PreToolUse": [
      .init(matcher: "", hooks: [.init(command: ClaudeHookSettings.busyOn, timeout: 5)])
    ],
    "Stop": [
      .init(hooks: [.init(command: ClaudeHookSettings.busyOff, timeout: 10)])
    ],
    "PostToolUseFailure": [
      .init(hooks: [.init(command: ClaudeHookSettings.busyOff, timeout: 5)])
    ],
    "SessionEnd": [
      .init(matcher: "", hooks: [.init(command: ClaudeHookSettings.busyOff, timeout: 1)])
    ],
  ]
}

// MARK: - Notification hooks.

// Stop forwards lastAssistantMessage, Notification forwards message/title.
private nonisolated struct ClaudeNotificationPayload: Encodable {
  let hooks: [String: [AgentHookGroup]] = [
    "Stop": [
      .init(hooks: [.init(command: ClaudeHookSettings.notify, timeout: 10)])
    ],
    "Notification": [
      .init(matcher: "", hooks: [.init(command: ClaudeHookSettings.notify, timeout: 10)])
    ],
  ]
}
