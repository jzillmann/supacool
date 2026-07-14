import Foundation
import Testing

@testable import Supacool

struct BoardFrozenDeckTests {
  @Test func detachedSessionsCollapseIntoTheDeck() {
    let sessions = [sampleSession(), sampleSession(), sampleSession()]

    let members = BoardFrozenDeck.members(
      visibleSessions: sessions,
      isExpanded: false,
      classify: { _ in .detached }
    )

    #expect(members.map(\.id) == sessions.map(\.id))
  }

  @Test func aSingleDetachedSessionIsNotWorthStacking() {
    let members = BoardFrozenDeck.members(
      visibleSessions: [sampleSession()],
      isExpanded: false,
      classify: { _ in .detached }
    )

    #expect(members.isEmpty)
  }

  @Test func expandedDeckHasNoMembers() {
    let members = BoardFrozenDeck.members(
      visibleSessions: [sampleSession(), sampleSession()],
      isExpanded: true,
      classify: { _ in .detached }
    )

    #expect(members.isEmpty)
  }

  @Test func onlyDetachedCollapses_interruptedAndDisconnectedKeepShouting() {
    let detachedA = sampleSession()
    let detachedB = sampleSession()
    let interrupted = sampleSession()
    let disconnected = sampleSession()

    let members = BoardFrozenDeck.members(
      visibleSessions: [detachedA, interrupted, detachedB, disconnected],
      isExpanded: false,
      classify: { session in
        switch session.id {
        case interrupted.id: .interrupted
        case disconnected.id: .disconnected
        default: .detached
        }
      }
    )

    #expect(members.map(\.id) == [detachedA.id, detachedB.id])
  }

  @Test func priorityFlaggedSessionsAreNeverSweptIn() {
    let plain = sampleSession()
    let alsoPlain = sampleSession()
    let flagged = sampleSession(isPriority: true)

    let members = BoardFrozenDeck.members(
      visibleSessions: [plain, flagged, alsoPlain],
      isExpanded: false,
      classify: { _ in .detached }
    )

    #expect(members.map(\.id) == [plain.id, alsoPlain.id])
  }

  @Test func priorityExemptionCanDropTheDeckBelowItsMinimum() {
    let plain = sampleSession()
    let flagged = sampleSession(isPriority: true)

    let members = BoardFrozenDeck.members(
      visibleSessions: [plain, flagged],
      isExpanded: false,
      classify: { _ in .detached }
    )

    #expect(members.isEmpty)
  }

  @Test func deckResumeRoutesSkipSessionsNoAutomaticResumeCanRevive() {
    let captured = sampleSession(agentNativeSessionID: "claude-session-1")
    let picker = sampleSession()
    let shell = sampleSession(agent: nil)

    let routes = BoardResumeEligibility.resumeRoutes(
      sessions: [captured, picker, shell],
      classify: { _ in .detached },
      tabExists: { _ in false }
    )

    #expect(routes == [.direct(captured.id), .picker(picker.id)])
  }

  private func sampleSession(
    agent: AgentType? = .claude,
    agentNativeSessionID: String? = nil,
    isPriority: Bool = false
  ) -> AgentSession {
    var session = AgentSession(
      id: UUID(),
      repositoryID: "/tmp/repo",
      worktreeID: "/tmp/repo",
      agent: agent,
      initialPrompt: "Fix the dashboard flicker",
      createdAt: Date(timeIntervalSinceReferenceDate: 0),
      lastActivityAt: Date(timeIntervalSinceReferenceDate: 0),
      agentNativeSessionID: agentNativeSessionID
    )
    session.isPriority = isPriority
    return session
  }
}
