import Foundation
import Testing

@testable import Supacool

/// Unit tests for the Stop-body classifier that grants a deferred-work
/// lease ("agent stopped its turn on purpose, waiting on a timed check").
/// Regression guard for trace BF99621E: a CI-triage evaluator holding for
/// live CI phrased its Stop messages in ways the phrase list missed, so
/// no lease was taken and Claude's idle reminder dropped the card into
/// Waiting on Me one minute into a multi-minute hold.
struct DeferredWorkSignalTests {
  private func stopNote(_ body: String) -> AgentHookNotification {
    AgentHookNotification(
      agent: "claude",
      event: "Stop",
      title: nil,
      body: body,
      sessionID: nil
    )
  }

  // MARK: - Orchestration-loop holds (verbatim from trace BF99621E)

  @Test func waitingOnLiveCIWithBackgroundPollerTakesLease() {
    let duration = WorktreeTerminalManager.deferredWorkLeaseDuration(
      for: stopNote(
        "evaluator: iter 3, step_8 waiting on live CI for PR #4346 with an "
          + "active background poller in the doer — not dormant, not blocked; "
          + "holding for the doer's next yield."
      )
    )
    // No explicit duration in the body → fallback TTL.
    #expect(duration == .seconds(15 * 60))
  }

  @Test func ciPollPendingInBackgroundTaskTakesLease() {
    let duration = WorktreeTerminalManager.deferredWorkLeaseDuration(
      for: stopNote(
        "evaluator: iter 3, step_8 still in_progress (CI poll pending in "
          + "doer's background task) — holding, no re-spawn while poller is live."
      )
    )
    #expect(duration == .seconds(15 * 60))
  }

  @Test func awaitingYieldTakesLease() {
    let duration = WorktreeTerminalManager.deferredWorkLeaseDuration(
      for: stopNote("evaluator: iter 1, doer spawned, awaiting yield.")
    )
    #expect(duration == .seconds(15 * 60))
  }

  // MARK: - Explicit durations still parse

  @Test func explicitMinutesParseWithBuffer() {
    let duration = WorktreeTerminalManager.deferredWorkLeaseDuration(
      for: stopNote("Will iterate on next 409 in ~7 min.")
    )
    // 7 min + the 90s lease buffer.
    #expect(duration == .seconds(7 * 60 + 90))
  }

  // MARK: - Non-deferred Stops must not take a lease

  @Test func finalSummaryStopTakesNoLease() {
    let duration = WorktreeTerminalManager.deferredWorkLeaseDuration(
      for: stopNote("Done. PR #2516 review fixes shipped.")
    )
    #expect(duration == nil)
  }

  @Test func realQuestionStopTakesNoLease() {
    let duration = WorktreeTerminalManager.deferredWorkLeaseDuration(
      for: stopNote("Should I also apply the fix to the staging config?")
    )
    #expect(duration == nil)
  }

  @Test func notificationEventTakesNoLease() {
    let note = AgentHookNotification(
      agent: "claude",
      event: "Notification",
      title: nil,
      body: "waiting on ci",
      sessionID: nil
    )
    #expect(WorktreeTerminalManager.deferredWorkLeaseDuration(for: note) == nil)
  }

  @Test func codexStopTakesNoLease() {
    let note = AgentHookNotification(
      agent: "codex",
      event: "Stop",
      title: nil,
      body: "waiting on ci",
      sessionID: nil
    )
    #expect(WorktreeTerminalManager.deferredWorkLeaseDuration(for: note) == nil)
  }
}
