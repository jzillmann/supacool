import Foundation
import Testing

@testable import Supacool

struct BoardVitalsTests {
  @Test func tallyBucketsEachStatus() {
    let sessions = [
      session(status: .waitingOnMe),
      session(status: .awaitingInput),
      session(status: .interrupted),
      session(status: .inProgress),
      session(status: .fresh),
      session(status: .waitingForChecks),
      session(status: .parked, parkedActive: true),
      session(status: .parked, parkedActive: false),
      session(status: .parked, parkedActive: false),
    ]
    let statuses = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, forcedStatus(of: $0)) })

    let vitals = BoardVitals.tally(sessions: sessions) { statuses[$0.id]! }

    #expect(vitals.waiting == 3)
    #expect(vitals.working == 2)
    #expect(vitals.external == 1)
    #expect(vitals.standby == 1)
    #expect(vitals.parked == 2)
    #expect(vitals.live == 6)
    #expect(vitals.total == 9)
  }

  @Test func emptyTally() {
    let vitals = BoardVitals.tally(sessions: []) { _ in .waitingOnMe }
    #expect(vitals == .empty)
    #expect(vitals.total == 0)
  }

  // MARK: - Helpers

  /// Encodes the desired classification into the session's initial prompt so
  /// the test's `classify` closure can hand it back deterministically without
  /// wiring up a live terminal manager.
  private func session(status: BoardSessionStatus, parkedActive: Bool = false) -> AgentSession {
    AgentSession(
      repositoryID: "/tmp/repo",
      worktreeID: "/tmp/repo",
      agent: .claude,
      initialPrompt: status.rawValue,
      parkedActive: parkedActive
    )
  }

  private func forcedStatus(of session: AgentSession) -> BoardSessionStatus {
    BoardSessionStatus(rawValue: session.initialPrompt) ?? .waitingOnMe
  }
}
