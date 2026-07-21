import Foundation
import Testing

@testable import Supacool

struct BoardSessionStatusTests {
  @Test func busySessionStaysInProgress() {
    let session = sampleSession(hasCompletedAtLeastOnce: true, lastKnownBusy: true)
    let status = BoardSessionStatus.classify(
      session: session,
      tabExists: true,
      activity: .working,
      now: Date(timeIntervalSinceReferenceDate: 100)
    )
    #expect(status == .inProgress)
  }

  @Test func deferredWorkSessionStaysInProgress() {
    let session = sampleSession(hasCompletedAtLeastOnce: true, lastKnownBusy: false)
    let status = BoardSessionStatus.classify(
      session: session,
      tabExists: true,
      activity: .deferredWork,
      now: Date(timeIntervalSinceReferenceDate: 100)
    )
    #expect(status == .inProgress)
  }

  @Test func recentBusyToIdleTransitionStaysInProgressBriefly() {
    let now = Date(timeIntervalSinceReferenceDate: 100)
    let session = sampleSession(
      hasCompletedAtLeastOnce: true,
      lastKnownBusy: false,
      lastBusyTransitionAt: now.addingTimeInterval(-0.5)
    )
    let status = BoardSessionStatus.classify(
      session: session,
      tabExists: true,
      activity: .idle,
      now: now
    )
    #expect(status == .inProgress)
  }

  @Test func firstIdleTurnUsesFreshDuringStabilizationWindow() {
    let now = Date(timeIntervalSinceReferenceDate: 100)
    let session = sampleSession(
      createdAt: now.addingTimeInterval(-10),
      hasCompletedAtLeastOnce: false,
      lastKnownBusy: false,
      lastBusyTransitionAt: now.addingTimeInterval(-0.5)
    )
    let status = BoardSessionStatus.classify(
      session: session,
      tabExists: true,
      activity: .idle,
      now: now
    )
    #expect(status == .fresh)
  }

  @Test func firstLaunchStillStartingWhileAgentInitializes() {
    let now = Date(timeIntervalSinceReferenceDate: 100)
    let session = sampleSession(
      createdAt: now.addingTimeInterval(-20),
      hasCompletedAtLeastOnce: false,
      lastKnownBusy: false
    )
    let status = BoardSessionStatus.classify(
      session: session,
      tabExists: true,
      activity: .idle,
      now: now
    )
    #expect(status == .fresh)
  }

  @Test func missingInitialBusyHookEventuallyFallsBackToWaiting() {
    let now = Date(timeIntervalSinceReferenceDate: 100)
    let session = sampleSession(
      createdAt: now.addingTimeInterval(-(BoardSessionStatus.missingInitialAgentEventGrace + 1)),
      hasCompletedAtLeastOnce: false,
      lastKnownBusy: false
    )
    let status = BoardSessionStatus.classify(
      session: session,
      tabExists: true,
      activity: .idle,
      now: now
    )
    #expect(status == .waitingOnMe)
  }

  @Test func observedInitialAgentEventCanMoveIdleSessionToWaitingImmediately() {
    let now = Date(timeIntervalSinceReferenceDate: 100)
    let session = sampleSession(
      createdAt: now.addingTimeInterval(-2),
      hasObservedInitialAgentEvent: true,
      lastKnownBusy: false
    )
    let status = BoardSessionStatus.classify(
      session: session,
      tabExists: true,
      activity: .idle,
      now: now
    )
    #expect(status == .waitingOnMe)
  }

  @Test func settledIdleSessionMovesToWaitingOnMe() {
    let now = Date(timeIntervalSinceReferenceDate: 100)
    let session = sampleSession(
      hasCompletedAtLeastOnce: true,
      lastKnownBusy: false,
      lastBusyTransitionAt: now.addingTimeInterval(-(BoardSessionStatus.idleRebucketDelay + 0.2))
    )
    let status = BoardSessionStatus.classify(
      session: session,
      tabExists: true,
      activity: .idle,
      now: now
    )
    #expect(status == .waitingOnMe)
  }

  @Test func startingSessionWinsOverPendingPullRequestChecks() {
    let now = Date(timeIntervalSinceReferenceDate: 100)
    let session = sampleSession(
      createdAt: now.addingTimeInterval(-10),
      hasCompletedAtLeastOnce: false,
      lastKnownBusy: false
    )
    let status = BoardSessionStatus.classify(
      session: session,
      tabExists: true,
      activity: .idle,
      waitingExternally: true,
      now: now
    )
    #expect(status == .fresh)
  }

  @Test func pendingPullRequestChecksUseExternalWaitingState() {
    let now = Date(timeIntervalSinceReferenceDate: 100)
    let session = sampleSession(
      hasCompletedAtLeastOnce: true,
      lastKnownBusy: false,
      lastBusyTransitionAt: now.addingTimeInterval(-(BoardSessionStatus.idleRebucketDelay + 0.2))
    )
    let status = BoardSessionStatus.classify(
      session: session,
      tabExists: true,
      activity: .idle,
      waitingExternally: true,
      now: now
    )
    #expect(status == .waitingForChecks)
  }

  @Test func busyAndAwaitingInputWinOverPendingPullRequestChecks() {
    let session = sampleSession(hasCompletedAtLeastOnce: true, lastKnownBusy: true)
    #expect(
      BoardSessionStatus.classify(
        session: session,
        tabExists: true,
        activity: .working,
        waitingExternally: true
      ) == .inProgress
    )
    #expect(
      BoardSessionStatus.classify(
        session: session,
        tabExists: true,
        activity: .wantsInput,
        waitingExternally: true
      ) == .awaitingInput
    )
  }

  @Test func awaitingInputWinsOverBusy() {
    let session = sampleSession(hasCompletedAtLeastOnce: true, lastKnownBusy: true)
    let status = BoardSessionStatus.classify(
      session: session,
      tabExists: true,
      activity: .wantsInput
    )
    #expect(status == .awaitingInput)
  }

  @Test func interruptedDetachedAndParkedStatesRemainStable() {
    let interrupted = sampleSession(lastKnownBusy: true)
    #expect(
      BoardSessionStatus.classify(
        session: interrupted,
        tabExists: false,
        activity: .idle
      ) == .interrupted
    )

    let detached = sampleSession(lastKnownBusy: false)
    #expect(
      BoardSessionStatus.classify(
        session: detached,
        tabExists: false,
        activity: .idle
      ) == .detached
    )

    var parked = sampleSession()
    parked.parked = true
    #expect(
      BoardSessionStatus.classify(
        session: parked,
        tabExists: true,
        activity: .working
      ) == .parked
    )
  }

  @Test func missingTabWinsOverPendingPullRequestChecks() {
    let session = sampleSession(lastKnownBusy: false)
    let status = BoardSessionStatus.classify(
      session: session,
      tabExists: false,
      activity: .idle,
      waitingExternally: true
    )
    #expect(status == .detached)
  }

  @Test func remoteSessionWithMissingTabIsDisconnected() {
    var remote = sampleSession()
    remote.remoteWorkspaceID = UUID()
    remote.remoteHostID = UUID()
    remote.tmuxSessionName = "supacool-xyz"
    #expect(
      BoardSessionStatus.classify(
        session: remote,
        tabExists: false,
        activity: .idle
      ) == .disconnected
    )
  }

  @Test func remoteSessionPrefersDisconnectedOverInterrupted() {
    // A remote session that was busy when the ssh link dropped used to
    // classify as `.interrupted` (local rule). Remote rule overrides.
    var remote = sampleSession(lastKnownBusy: true)
    remote.remoteWorkspaceID = UUID()
    #expect(
      BoardSessionStatus.classify(
        session: remote,
        tabExists: false,
        activity: .idle
      ) == .disconnected
    )
  }

  @Test func manualOverrideWinsOverBusy() {
    var session = sampleSession(hasCompletedAtLeastOnce: true, lastKnownBusy: true)
    session.manualStatusOverride = .waitingOnMe
    let status = BoardSessionStatus.classify(
      session: session,
      tabExists: true,
      activity: .working
    )
    #expect(status == .waitingOnMe)
  }

  @Test func manualOverrideWinsOverAwaitingInput() {
    var session = sampleSession(hasCompletedAtLeastOnce: true)
    session.manualStatusOverride = .inProgress
    let status = BoardSessionStatus.classify(
      session: session,
      tabExists: true,
      activity: .wantsInput
    )
    #expect(status == .inProgress)
  }

  @Test func manualOverrideIgnoredWhenTabMissing() {
    var session = sampleSession(hasCompletedAtLeastOnce: true, lastKnownBusy: true)
    session.manualStatusOverride = .inProgress
    let status = BoardSessionStatus.classify(
      session: session,
      tabExists: false,
      activity: .idle
    )
    // Tab is gone → interrupted/detached path runs, override is irrelevant.
    #expect(status == .interrupted)
  }

  @Test func manualOverrideIgnoredWhenParked() {
    var session = sampleSession(hasCompletedAtLeastOnce: true)
    session.parked = true
    session.manualStatusOverride = .inProgress
    let status = BoardSessionStatus.classify(
      session: session,
      tabExists: true,
      activity: .idle
    )
    #expect(status == .parked)
  }

  private func sampleSession(
    createdAt: Date = Date(timeIntervalSinceReferenceDate: 0),
    hasCompletedAtLeastOnce: Bool = false,
    hasObservedInitialAgentEvent: Bool = false,
    lastKnownBusy: Bool = false,
    lastBusyTransitionAt: Date? = nil
  ) -> AgentSession {
    AgentSession(
      repositoryID: "/tmp/repo",
      worktreeID: "/tmp/repo",
      agent: .claude,
      initialPrompt: "Fix the dashboard flicker",
      createdAt: createdAt,
      lastActivityAt: createdAt,
      hasCompletedAtLeastOnce: hasCompletedAtLeastOnce,
      hasObservedInitialAgentEvent: hasObservedInitialAgentEvent,
      lastKnownBusy: lastKnownBusy,
      lastBusyTransitionAt: lastBusyTransitionAt
    )
  }
}
