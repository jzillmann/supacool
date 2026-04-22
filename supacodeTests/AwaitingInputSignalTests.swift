import Foundation
import Testing

@testable import Supacool

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

  @Test func codexPermissionRequestIsAwaitingInput() {
    let note = AgentHookNotification(
      agent: "codex",
      event: "PermissionRequest",
      title: nil,
      body: "approve shell escalation?",
      sessionID: nil
    )
    #expect(WorktreeTerminalManager.isAwaitingInputSignal(note))
  }

  @Test func codexStopIsNotAwaitingInput() {
    let note = AgentHookNotification(
      agent: "codex",
      event: "Stop",
      title: nil,
      body: "finished turn",
      sessionID: nil
    )
    #expect(!WorktreeTerminalManager.isAwaitingInputSignal(note))
  }

  /// Forward-compat: if Codex ever grows a Notification event, treat it
  /// as blocking until we can audit its payloads.
  @Test func codexNotificationEventStillTreatedAsAwaitingInput() {
    let note = AgentHookNotification(
      agent: "codex",
      event: "Notification",
      title: nil,
      body: "anything",
      sessionID: nil
    )
    #expect(WorktreeTerminalManager.isAwaitingInputSignal(note))
  }

  @Test func approvalPromptScreenMatchesFallbackClassifier() {
    let screen = """
      Do you want to make this edit to e2e-no-silent-failures.md?
      1. Yes
      2. Yes, and allow Claude to edit its own settings for this session
      3. No

      Esc to cancel  Tab to amend
      """
    #expect(WorktreeTerminalManager.isAwaitingInputPromptScreen(screen))
  }

  @Test func genericStaticYesNoScreenDoesNotMatchFallbackClassifier() {
    let screen = """
      Proposed plan:
      1. Yes
      2. No

      Waiting for more output...
      """
    #expect(!WorktreeTerminalManager.isAwaitingInputPromptScreen(screen))
  }
}
