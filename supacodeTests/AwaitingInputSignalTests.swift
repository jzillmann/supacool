import Foundation
import Testing

@testable import supacode

/// Unit tests for the `Notification`-event filter that decides whether a hook
/// payload represents an agent actually blocking on user input. Regression
/// guard for the Matrix Board misclassifying long-running Claude turns as
/// "Wants Input" (every `Notification` event used to flip the card).
struct AwaitingInputSignalTests {
  @Test func claudePermissionPromptIsAwaitingInput() {
    let note = AgentHookNotification(
      agent: "claude",
      event: "Notification",
      title: nil,
      body: "Claude needs your permission to use Bash",
      sessionID: nil
    )
    #expect(WorktreeTerminalManager.isAwaitingInputSignal(note))
  }

  @Test func claudeIdleReminderIsAwaitingInput() {
    let note = AgentHookNotification(
      agent: "claude",
      event: "Notification",
      title: nil,
      body: "Claude is waiting for your input",
      sessionID: nil
    )
    #expect(WorktreeTerminalManager.isAwaitingInputSignal(note))
  }

  @Test func claudeInformationalNotificationIsNotAwaitingInput() {
    let note = AgentHookNotification(
      agent: "claude",
      event: "Notification",
      title: nil,
      body: "Edited supacode/Foo.swift",
      sessionID: nil
    )
    #expect(!WorktreeTerminalManager.isAwaitingInputSignal(note))
  }

  @Test func claudeNotificationWithoutBodyIsNotAwaitingInput() {
    let note = AgentHookNotification(
      agent: "claude",
      event: "Notification",
      title: nil,
      body: nil,
      sessionID: nil
    )
    #expect(!WorktreeTerminalManager.isAwaitingInputSignal(note))
  }

  @Test func stopEventNeverAwaitingInput() {
    let note = AgentHookNotification(
      agent: "claude",
      event: "Stop",
      title: nil,
      body: "Claude needs your permission to use Bash",
      sessionID: nil
    )
    #expect(!WorktreeTerminalManager.isAwaitingInputSignal(note))
  }

  @Test func codexPreservesLegacyBehavior() {
    let note = AgentHookNotification(
      agent: "codex",
      event: "Notification",
      title: nil,
      body: "anything",
      sessionID: nil
    )
    #expect(WorktreeTerminalManager.isAwaitingInputSignal(note))
  }
}
