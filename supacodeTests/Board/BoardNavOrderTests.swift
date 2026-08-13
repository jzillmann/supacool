import Foundation
import Testing

@testable import Supacool

@MainActor
struct BoardNavOrderTests {
  @Test func nextInSameStateSkipsOtherBucketsWithoutWrapping() {
    let waitingA = makeSession(1)
    let workingA = makeSession(2)
    let waitingB = makeSession(3)
    let parked = makeSession(4)
    let workingB = makeSession(5)
    let sessions = [waitingA, workingA, waitingB, parked, workingB]
    let statuses: [AgentSession.ID: BoardSessionStatus] = [
      waitingA.id: .waitingOnMe,
      workingA.id: .inProgress,
      waitingB.id: .awaitingInput,
      parked.id: .parked,
      workingB.id: .inProgress,
    ]

    #expect(
      BoardNavOrder.nextInSameState(
        after: waitingA.id,
        visibleSessions: sessions,
        classify: { statuses[$0.id]! }
      ) == waitingB.id
    )
    #expect(
      BoardNavOrder.nextInSameState(
        after: workingA.id,
        visibleSessions: sessions,
        classify: { statuses[$0.id]! }
      ) == workingB.id
    )
    #expect(
      BoardNavOrder.nextInSameState(
        after: waitingB.id,
        visibleSessions: sessions,
        classify: { statuses[$0.id]! }
      ) == nil
    )
    #expect(
      BoardNavOrder.nextInSameState(
        after: parked.id,
        visibleSessions: sessions,
        classify: { statuses[$0.id]! }
      ) == nil
    )
  }

  @Test func previousInSameStateSkipsOtherBucketsWithoutWrapping() {
    let waitingA = makeSession(1)
    let workingA = makeSession(2)
    let waitingB = makeSession(3)
    let parked = makeSession(4)
    let workingB = makeSession(5)
    let sessions = [waitingA, workingA, waitingB, parked, workingB]
    let statuses: [AgentSession.ID: BoardSessionStatus] = [
      waitingA.id: .waitingOnMe,
      workingA.id: .inProgress,
      waitingB.id: .awaitingInput,
      parked.id: .parked,
      workingB.id: .inProgress,
    ]

    #expect(
      BoardNavOrder.previousInSameState(
        before: waitingB.id,
        visibleSessions: sessions,
        classify: { statuses[$0.id]! }
      ) == waitingA.id
    )
    #expect(
      BoardNavOrder.previousInSameState(
        before: workingB.id,
        visibleSessions: sessions,
        classify: { statuses[$0.id]! }
      ) == workingA.id
    )
    #expect(
      BoardNavOrder.previousInSameState(
        before: waitingA.id,
        visibleSessions: sessions,
        classify: { statuses[$0.id]! }
      ) == nil
    )
    #expect(
      BoardNavOrder.previousInSameState(
        before: parked.id,
        visibleSessions: sessions,
        classify: { statuses[$0.id]! }
      ) == nil
    )
  }

  @Test func nextInSameStateCanUseCapturedStatusForCurrentSession() {
    let waitingA = makeSession(1)
    let working = makeSession(2)
    let waitingB = makeSession(3)
    let sessions = [waitingA, working, waitingB]
    let liveStatuses: [AgentSession.ID: BoardSessionStatus] = [
      waitingA.id: .inProgress,
      working.id: .inProgress,
      waitingB.id: .waitingOnMe,
    ]

    #expect(
      BoardNavOrder.nextInSameState(
        after: waitingA.id,
        visibleSessions: sessions,
        currentStatusOverride: .waitingOnMe,
        classify: { liveStatuses[$0.id]! }
      ) == waitingB.id
    )
  }

  @Test func previousInSameStateCanUseCapturedStatusForCurrentSession() {
    let waitingA = makeSession(1)
    let working = makeSession(2)
    let waitingB = makeSession(3)
    let sessions = [waitingA, working, waitingB]
    let liveStatuses: [AgentSession.ID: BoardSessionStatus] = [
      waitingA.id: .waitingOnMe,
      working.id: .inProgress,
      waitingB.id: .inProgress,
    ]

    #expect(
      BoardNavOrder.previousInSameState(
        before: waitingB.id,
        visibleSessions: sessions,
        currentStatusOverride: .waitingOnMe,
        classify: { liveStatuses[$0.id]! }
      ) == waitingA.id
    )
  }

  @Test func nextInSameStateAdvancesFromMiddleOfBucket() {
    let waitingA = makeSession(1)
    let working = makeSession(2)
    let waitingB = makeSession(3)
    let parked = makeSession(4)
    let waitingC = makeSession(5)
    let sessions = [waitingA, working, waitingB, parked, waitingC]
    let statuses: [AgentSession.ID: BoardSessionStatus] = [
      waitingA.id: .waitingOnMe,
      working.id: .inProgress,
      waitingB.id: .awaitingInput,
      parked.id: .parked,
      waitingC.id: .detached,
    ]

    #expect(
      BoardNavOrder.nextInSameState(
        after: waitingB.id,
        visibleSessions: sessions,
        classify: { statuses[$0.id]! }
      ) == waitingC.id
    )
  }

  @Test func orderPutsPrioritySessionsFirstWithinEachLiveBucket() {
    let waiting = makeSession(1)
    let priorityWaiting = makeSession(2, isPriority: true)
    let working = makeSession(3)
    let priorityWorking = makeSession(4, isPriority: true)
    let priorityParked = makeSession(5, isPriority: true)
    let sessions = [waiting, priorityWaiting, working, priorityWorking, priorityParked]
    let statuses: [AgentSession.ID: BoardSessionStatus] = [
      waiting.id: .waitingOnMe,
      priorityWaiting.id: .awaitingInput,
      working.id: .inProgress,
      priorityWorking.id: .waitingForChecks,
      priorityParked.id: .parked,
    ]

    #expect(
      BoardNavOrder.order(
        visibleSessions: sessions,
        classify: { statuses[$0.id]! }
      ) == [priorityWaiting.id, waiting.id, priorityWorking.id, working.id]
    )
  }

  @Test func nextInSameStateFollowsPriorityFirstBucketOrder() {
    let waiting = makeSession(1)
    let priorityWaiting = makeSession(2, isPriority: true)
    let waitingAfterPriority = makeSession(3)
    let sessions = [waiting, priorityWaiting, waitingAfterPriority]

    #expect(
      BoardNavOrder.nextInSameState(
        after: priorityWaiting.id,
        visibleSessions: sessions,
        classify: { _ in .waitingOnMe }
      ) == waiting.id
    )
    #expect(
      BoardNavOrder.nextInSameState(
        after: waiting.id,
        visibleSessions: sessions,
        classify: { _ in .waitingOnMe }
      ) == waitingAfterPriority.id
    )
    #expect(
      BoardNavOrder.nextInSameState(
        after: waitingAfterPriority.id,
        visibleSessions: sessions,
        classify: { _ in .waitingOnMe }
      ) == nil
    )
  }

  @Test func checksPendingIsItsOwnBucket() {
    let waiting = makeSession(1)
    let checksA = makeSession(2)
    let working = makeSession(3)
    let checksB = makeSession(4)
    let sessions = [waiting, checksA, working, checksB]
    let statuses: [AgentSession.ID: BoardSessionStatus] = [
      waiting.id: .waitingOnMe,
      checksA.id: .waitingForChecks,
      working.id: .inProgress,
      checksB.id: .waitingForChecks,
    ]

    // Cursor cycles within Checks Pending only — In Progress is skipped.
    #expect(
      BoardNavOrder.nextInSameState(
        after: checksA.id,
        visibleSessions: sessions,
        classify: { statuses[$0.id]! }
      ) == checksB.id
    )

    // And the row order in `order(...)` puts Checks Pending between
    // Waiting on Me and In Progress.
    #expect(
      BoardNavOrder.order(
        visibleSessions: sessions,
        classify: { statuses[$0.id]! }
      ) == [waiting.id, checksA.id, checksB.id, working.id]
    )
  }

  @Test func nextInSameStateReturnsNilWhenCurrentSessionIsNotVisible() {
    let visible = makeSession(1)
    let hidden = makeSession(2)

    #expect(
      BoardNavOrder.nextInSameState(
        after: hidden.id,
        visibleSessions: [visible],
        classify: { _ in .waitingOnMe }
      ) == nil
    )
  }

  @Test func navAnchorSurvivesTheBusyBlipInEveryIdleLane() {
    // Answering a card starts the agent; ⌘. must still walk the lane the
    // user entered. Waiting on External is a lane too — anchoring only the
    // attention lane used to dump ⌘. into In Progress from an external card.
    #expect(BoardNavOrder.shouldPreserveNavAnchor(.waitingOnMe, liveStatus: .inProgress))
    #expect(BoardNavOrder.shouldPreserveNavAnchor(.awaitingInput, liveStatus: .fresh))
    #expect(BoardNavOrder.shouldPreserveNavAnchor(.waitingForChecks, liveStatus: .inProgress))
    #expect(BoardNavOrder.shouldPreserveNavAnchor(.parked, liveStatus: .inProgress))
  }

  @Test func navAnchorFollowsTheCardWhenItSettlesInAnotherLane() {
    // Anything that isn't the busy blip is a real lane change — the anchor
    // gives way so ⌘. keeps matching the lane the card is drawn in.
    #expect(!BoardNavOrder.shouldPreserveNavAnchor(.waitingOnMe, liveStatus: .waitingForChecks))
    #expect(!BoardNavOrder.shouldPreserveNavAnchor(.waitingForChecks, liveStatus: .waitingOnMe))
    #expect(!BoardNavOrder.shouldPreserveNavAnchor(.waitingOnMe, liveStatus: .detached))
    // A busy anchor never outranks the live status.
    #expect(!BoardNavOrder.shouldPreserveNavAnchor(.inProgress, liveStatus: .fresh))
    #expect(!BoardNavOrder.shouldPreserveNavAnchor(.inProgress, liveStatus: .waitingForChecks))
  }

  private func makeSession(_ suffix: Int, isPriority: Bool = false) -> AgentSession {
    AgentSession(
      id: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(suffix)")!,
      repositoryID: "/repo",
      worktreeID: "/repo/session-\(suffix)",
      agent: .claude,
      initialPrompt: "Session \(suffix)",
      isPriority: isPriority
    )
  }
}
