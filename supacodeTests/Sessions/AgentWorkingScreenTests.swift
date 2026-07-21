import Foundation
import Testing

@testable import Supacool

/// Unit tests for the screen classifier that reads the agent's own interrupt
/// hint as proof it owns the turn.
///
/// Regression guard for trace D5AF6FE4: Claude spent 2.5 minutes on a single
/// stretch of model thinking, which emits no busy hook at all (`UserPromptSubmit`
/// and `PreToolUse` are the only busy-on edges). The board had already cleared
/// the busy latch on the blocking-tool Notification and let the awaiting lease
/// expire, so the card sat in "Waiting" while the screen plainly read
/// "thinking more". The footer was the one signal that never lied.
struct AgentWorkingScreenTests {
  @Test func claudeThinkingFooterIsWorking() {
    let screen = """
      ⏺ I'll plan CEN-7715 now.

      ✻ Growing… (3× 47s · ↑ 4.3k tokens · esc to interrupt)
      """
    #expect(WorktreeTerminalManager.isAgentWorkingScreen(screen))
  }

  @Test func claudeToolRunFooterIsWorking() {
    let screen = """
      ⏺ Bash(go test ./...)
        ⎿ Running…

      ✻ Simmering… (12s · ↓ 1.2k tokens · esc to interrupt)
      """
    #expect(WorktreeTerminalManager.isAgentWorkingScreen(screen))
  }

  @Test func interruptHintIsCaseInsensitive() {
    #expect(WorktreeTerminalManager.isAgentWorkingScreen("Working… (Esc To Interrupt)"))
  }

  @Test func ctrlCInterruptHintIsWorking() {
    #expect(WorktreeTerminalManager.isAgentWorkingScreen("thinking (ctrl+c to interrupt)"))
  }

  /// The critical non-collision. Claude's *approval prompt* footer reads
  /// "Esc to cancel" — the exact opposite state. Matching on "cancel" would
  /// classify a permission prompt as working and pin the card green while it
  /// silently waits on the user.
  @Test func approvalPromptIsNotWorking() {
    let screen = """
      Do you want to make this edit to e2e-no-silent-failures.md?
      1. Yes
      2. Yes, and allow Claude to edit its own settings for this session
      3. No

      Esc to cancel  Tab to amend
      """
    #expect(!WorktreeTerminalManager.isAgentWorkingScreen(screen))
    // ...and it still reads as the awaiting prompt it actually is.
    #expect(WorktreeTerminalManager.isAwaitingInputPromptScreen(screen))
  }

  @Test func idlePromptIsNotWorking() {
    let screen = """
      ⏺ Done — plan posted to Linear.

      >
      """
    #expect(!WorktreeTerminalManager.isAgentWorkingScreen(screen))
  }

  @Test func emptyScreenIsNotWorking() {
    #expect(!WorktreeTerminalManager.isAgentWorkingScreen(""))
  }
}
