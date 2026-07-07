import Foundation
import Testing

@testable import Supacool

struct BoardResumeEligibilityTests {
  @Test func selectedRoutesIncludeCapturedAndPickerResumeSessions() {
    let directID = UUID()
    let pickerID = UUID()
    let liveID = UUID()
    let direct = sampleSession(id: directID, agentNativeSessionID: "claude-session-1")
    let picker = sampleSession(id: pickerID)
    let live = sampleSession(id: liveID, agentNativeSessionID: "claude-session-2")

    let routes = BoardResumeEligibility.selectedResumeRoutes(
      sessions: [direct, picker, live],
      selectedIDs: [directID, pickerID, liveID],
      classify: { session in
        session.id == liveID ? .waitingOnMe : .detached
      },
      tabExists: { _ in false }
    )

    #expect(routes == [.direct(directID), .picker(pickerID)])
  }

  @Test func singleSelectedSessionDoesNotCreateBulkResumeRoute() {
    let id = UUID()
    let session = sampleSession(id: id, agentNativeSessionID: "claude-session-1")

    let routes = BoardResumeEligibility.selectedResumeRoutes(
      sessions: [session],
      selectedIDs: [id],
      classify: { _ in .detached },
      tabExists: { _ in false }
    )

    #expect(routes.isEmpty)
  }

  @Test func emptyCapturedSessionIDFallsBackToPickerRoute() {
    let id = UUID()
    let otherID = UUID()
    let session = sampleSession(id: id, agentNativeSessionID: "")
    let live = sampleSession(id: otherID, agentNativeSessionID: "other")

    let routes = BoardResumeEligibility.selectedResumeRoutes(
      sessions: [session, live],
      selectedIDs: [id, otherID],
      classify: { session in
        session.id == otherID ? .waitingOnMe : .detached
      },
      tabExists: { _ in false }
    )

    #expect(routes == [.picker(id)])
  }

  @Test func pickerRouteRequiresAgentPickerSupport() {
    let id = UUID()
    let otherID = UUID()
    let session = sampleSession(id: id, agent: unsupportedResumeAgent)
    let live = sampleSession(id: otherID, agentNativeSessionID: "other")

    let routes = BoardResumeEligibility.selectedResumeRoutes(
      sessions: [session, live],
      selectedIDs: [id, otherID],
      classify: { session in
        session.id == otherID ? .waitingOnMe : .detached
      },
      tabExists: { _ in false }
    )

    #expect(routes.isEmpty)
  }

  @Test func parkedSessionsOnlyResumeWhenTheyHaveNoLiveTab() {
    let dormantDirectID = UUID()
    let dormantPickerID = UUID()
    let activeParkedID = UUID()
    let dormantDirect = sampleSession(id: dormantDirectID, agentNativeSessionID: "claude-session-1")
    let dormantPicker = sampleSession(id: dormantPickerID)
    let activeParked = sampleSession(id: activeParkedID, agentNativeSessionID: "claude-session-2")

    let routes = BoardResumeEligibility.selectedResumeRoutes(
      sessions: [dormantDirect, dormantPicker, activeParked],
      selectedIDs: [dormantDirectID, dormantPickerID, activeParkedID],
      classify: { _ in .parked },
      tabExists: { session in session.id == activeParkedID }
    )

    #expect(routes == [.direct(dormantDirectID), .picker(dormantPickerID)])
  }

  private func sampleSession(
    id: UUID,
    agent: AgentType? = .claude,
    agentNativeSessionID: String? = nil
  ) -> AgentSession {
    AgentSession(
      id: id,
      repositoryID: "/tmp/repo",
      worktreeID: "/tmp/repo",
      agent: agent,
      initialPrompt: "Fix the dashboard flicker",
      createdAt: Date(timeIntervalSinceReferenceDate: 0),
      lastActivityAt: Date(timeIntervalSinceReferenceDate: 0),
      agentNativeSessionID: agentNativeSessionID
    )
  }

  private var unsupportedResumeAgent: AgentType {
    AgentType(
      id: "unsupported",
      displayName: "Unsupported",
      binary: "unsupported",
      bypassPermissionsFlag: nil,
      supportsPlanMode: false,
      icon: .symbol("terminal"),
      tintColorName: "secondary"
    )
  }
}
