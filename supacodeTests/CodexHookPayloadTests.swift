import Foundation
import Testing

@testable import Supacool

/// Regression tests for the Codex hook payload. Guards the Supacool-added
/// `PreToolUse` (Bash matcher) and `PermissionRequest` entries that
/// (a) clear "Wants Input" the moment Codex resumes from a permission
/// prompt and (b) give the Matrix Board a clean signal that a Codex
/// card is blocked on approval.
struct CodexHookPayloadTests {
  // MARK: - Progress payload.

  @Test func progressPayloadIncludesPreToolUseBusyOnWithBashMatcher() throws {
    let groups = try CodexHookSettings.progressHookGroupsByEvent()
    guard let entries = groups["PreToolUse"], let group = entries.first else {
      Issue.record("Expected PreToolUse entry in Codex progress hooks")
      return
    }
    #expect(group.objectValue?["matcher"]?.stringValue == "Bash")
    let hooks = group.objectValue?["hooks"]?.arrayValue ?? []
    let commands = hooks.compactMap { $0.objectValue?["command"]?.stringValue }
    #expect(commands == [AgentHookSettingsCommand.busyCommand(active: true)])
  }

  @Test func existingCodexProgressEventsStillPresent() throws {
    let groups = try CodexHookSettings.progressHookGroupsByEvent()
    #expect(groups["UserPromptSubmit"] != nil)
    #expect(groups["Stop"] != nil)
  }

  // MARK: - Notification payload.

  @Test func notificationPayloadIncludesPermissionRequestForward() throws {
    let groups = try CodexHookSettings.notificationHookGroupsByEvent()
    guard let entries = groups["PermissionRequest"], let group = entries.first else {
      Issue.record("Expected PermissionRequest entry in Codex notification hooks")
      return
    }
    let hooks = group.objectValue?["hooks"]?.arrayValue ?? []
    let commands = hooks.compactMap { $0.objectValue?["command"]?.stringValue }
    #expect(commands == [AgentHookSettingsCommand.notificationCommand(agent: "codex")])
  }

  @Test func notificationPayloadRetainsStopForwarder() throws {
    let groups = try CodexHookSettings.notificationHookGroupsByEvent()
    #expect(groups["Stop"] != nil)
  }
}
