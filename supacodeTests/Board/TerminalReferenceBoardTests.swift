import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Sharing
import Testing

@testable import Supacool

@MainActor
@Suite("Board terminal references")
struct TerminalReferenceBoardTests {
  private static let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)

  private func session(_ references: [SessionReference]) -> AgentSession {
    AgentSession(
      repositoryID: "/tmp/repo",
      worktreeID: "/tmp/repo",
      agent: .claude,
      initialPrompt: "x",
      displayName: "x",
      references: references
    )
  }

  @Test(.dependencies) func pulseTickFetchesReferencedTicketsAndPublishesCatalog() async {
    let requested = LockIsolated<[[String]]>([])
    var state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session([.ticket(id: "CEN-7"), .ticket(id: "CEN-8")])] }
    let store = TestStore(initialState: state) {
      BoardFeature()
    } withDependencies: {
      $0.date = .constant(Self.fixedDate)
      $0[LinearClient.self].fetchIssues = { ids in
        requested.withValue { $0.append(ids) }
        return [
          LinearIssue(
            id: "uuid", identifier: "CEN-7", title: "Fix it", stateName: "In Review", stateType: "started",
            assignedToMe: false, stateColor: "#0f783c"
          ),
        ]
      }
    }

    await store.send(._runPRPulseTick) {
      $0.terminalTicketFetchInFlight = true
    }
    let issue = LinearIssue(
      id: "uuid", identifier: "CEN-7", title: "Fix it", stateName: "In Review", stateType: "started",
      assignedToMe: false, stateColor: "#0f783c"
    )
    await store.receive(._terminalTicketsLoaded(attempted: ["CEN-7", "CEN-8"], issues: [issue])) {
      $0.terminalTicketFetchInFlight = false
      $0.terminalTicketAttemptedAt = ["CEN-7": Self.fixedDate, "CEN-8": Self.fixedDate]
      $0.terminalTicketIssues = ["CEN-7": issue]
    }
    #expect(requested.value == [["CEN-7", "CEN-8"]])

    @Shared(.terminalReferenceCatalog) var catalog
    #expect(catalog.tickets["CEN-7"]?.stateName == "In Review")

    // Fresh attempts are not refetched on the next tick.
    await store.send(._runPRPulseTick)
  }

  @Test func candidatesPreferNeverFetchedThenOldest() {
    let now = Self.fixedDate
    let sessions = [session([.ticket(id: "A-1"), .ticket(id: "A-2"), .ticket(id: "A-3"), .ticket(id: "A-1")])]
    let ids = BoardFeature.terminalTicketCandidates(
      sessions: sessions,
      attemptedAt: [
        "A-1": now.addingTimeInterval(-600),
        "A-2": now.addingTimeInterval(-60),
      ],
      now: now
    )
    #expect(ids == ["A-3", "A-1"])
  }
}
