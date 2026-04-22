import Foundation
import Testing

@testable import Supacool

/// Regression tests for the Claude progress hook payload. Guards the
/// Supacool-added `PreToolUse` entry that clears "Wants Input" the moment
/// Claude resumes after a permission grant, instead of waiting on the
/// screen-fingerprint poll (1s) or the 8s awaiting-input TTL.
struct ClaudeProgressHookTests {
  @Test func progressPayloadIncludesPreToolUseBusyOn() throws {
    let groups = try ClaudeHookSettings.progressHookGroupsByEvent()
    guard let entries = groups["PreToolUse"], let group = entries.first else {
      Issue.record("Expected PreToolUse entry in progress hooks")
      return
    }
    let hooks = group.objectValue?["hooks"]?.arrayValue ?? []
    let commands = hooks.compactMap { $0.objectValue?["command"]?.stringValue }
    #expect(commands == [AgentHookSettingsCommand.busyCommand(active: true)])
  }

  @Test func preToolUseUsesExplicitEmptyMatcher() throws {
    let groups = try ClaudeHookSettings.progressHookGroupsByEvent()
    let matcher = groups["PreToolUse"]?.first?.objectValue?["matcher"]?.stringValue
    #expect(matcher == "")
  }

  @Test func preToolUseTimeoutIsShortEnoughToNotStallEveryTool() throws {
    let groups = try ClaudeHookSettings.progressHookGroupsByEvent()
    let timeoutValue = groups["PreToolUse"]?
      .first?.objectValue?["hooks"]?.arrayValue?
      .first?.objectValue?["timeout"]
    #expect(timeoutValue == .int(5))
  }

  @Test func existingProgressEventsStillPresent() throws {
    let groups = try ClaudeHookSettings.progressHookGroupsByEvent()
    #expect(groups["UserPromptSubmit"] != nil)
    #expect(groups["Stop"] != nil)
    #expect(groups["PostToolUseFailure"] != nil)
    #expect(groups["SessionEnd"] != nil)
  }
}
