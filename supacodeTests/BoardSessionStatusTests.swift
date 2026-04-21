import Foundation
import Testing

@testable import Supacool

struct BoardSessionStatusTests {
  @Test func busySessionStaysInProgress() {
    let session = sampleSession(hasCompletedAtLeastOnce: true, lastKnownBusy: true)
    let status = BoardSessionStatus.classify(
      session: session,
      tabExists: true,
      awaitingInput: false,
      busy: true,
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
      awaitingInput: false,
      busy: false,
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
      awaitingInput: false,
      busy: false,
      now: now
    )
    #expect(status == .fresh)
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
      awaitingInput: false,
      busy: false,
      now: now
    )
    #expect(status == .waitingOnMe)
  }

  @Test func awaitingInputWinsOverBusy() {
    let session = sampleSession(hasCompletedAtLeastOnce: true, lastKnownBusy: true)
    let status = BoardSessionStatus.classify(
      session: session,
      tabExists: true,
      awaitingInput: true,
      busy: true
    )
    #expect(status == .awaitingInput)
  }

  @Test func interruptedDetachedAndParkedStatesRemainStable() {
    let interrupted = sampleSession(lastKnownBusy: true)
    #expect(
      BoardSessionStatus.classify(
        session: interrupted,
        tabExists: false,
        awaitingInput: false,
        busy: false
      ) == .interrupted
    )

    let detached = sampleSession(lastKnownBusy: false)
    #expect(
      BoardSessionStatus.classify(
        session: detached,
        tabExists: false,
        awaitingInput: false,
        busy: false
      ) == .detached
    )

    var parked = sampleSession()
    parked.parked = true
    #expect(
      BoardSessionStatus.classify(
        session: parked,
        tabExists: true,
        awaitingInput: false,
        busy: true
      ) == .parked
    )
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
        awaitingInput: false,
        busy: false
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
        awaitingInput: false,
        busy: false
      ) == .disconnected
    )
  }

  private func sampleSession(
    createdAt: Date = Date(timeIntervalSinceReferenceDate: 0),
    hasCompletedAtLeastOnce: Bool = false,
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
      lastKnownBusy: lastKnownBusy,
      lastBusyTransitionAt: lastBusyTransitionAt
    )
  }
}
