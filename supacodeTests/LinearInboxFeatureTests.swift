import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Testing

@testable import Supacool

// MARK: - Ticket id parsing (pure)

struct LinearTicketParsingTests {
  /// The allowlist is read from UserDefaults; pin it empty so parsing is
  /// deterministic regardless of the host's configured prefixes.
  private func clearAllowlist() {
    UserDefaults.standard.set("", forKey: "supacool.references.ticketPrefixes")
  }

  @Test func extractsIDsFromPastedURLsAndBareIDs() {
    clearAllowlist()
    let text = """
      https://linear.app/centrum-ai/issue/CEN-7404/the-success-and-failed-status-icons
      https://linear.app/centrum-ai/issue/CEN-7405/when-navigating-to-the-notifications
      Don't forget CEN-7404 (dupe) and ABC-12.
      """
    #expect(linearTicketIDs(in: text) == ["CEN-7404", "CEN-7405", "ABC-12"])
  }

  @Test func honorsPrefixAllowlist() {
    UserDefaults.standard.set("CEN", forKey: "supacool.references.ticketPrefixes")
    defer { UserDefaults.standard.set("", forKey: "supacool.references.ticketPrefixes") }
    let text = "CEN-1 and ABC-2 and CEN-3"
    #expect(linearTicketIDs(in: text) == ["CEN-1", "CEN-3"])
  }

  @Test func returnsEmptyWhenNoTickets() {
    clearAllowlist()
    #expect(linearTicketIDs(in: "nothing to see").isEmpty)
    #expect(linearTicketIDs(in: "").isEmpty)
  }

  @Test func firstTicketIsTheFirstMatch() {
    clearAllowlist()
    #expect(firstLinearTicketID(in: "see CEN-9 then CEN-10") == "CEN-9")
  }
}

// MARK: - Done derivation (pure)

struct LinearTicketDoneTests {
  @Test func isDoneReflectsLinearStateType() {
    #expect(LinearTicket(identifier: "A-1", stateType: "completed").isDone)
    #expect(LinearTicket(identifier: "A-2", stateType: "canceled").isDone)
    #expect(!LinearTicket(identifier: "A-3", stateType: "started").isDone)
    #expect(!LinearTicket(identifier: "A-4", stateType: "backlog").isDone)
    // Unfetched tickets (no state) are never done.
    #expect(!LinearTicket(identifier: "A-5").isDone)
  }
}

// MARK: - Reducer

@MainActor
struct LinearInboxFeatureTests {
  private func resetInbox(_ tickets: [LinearTicket]) {
    @Shared(.linearInbox) var inbox: [LinearTicket]
    $inbox.withLock { $0 = tickets }
    UserDefaults.standard.set("", forKey: "supacool.references.ticketPrefixes")
  }

  @Test(.dependencies) func importParsesPastedTextThenFetchesMetadata() async {
    resetInbox([])
    let now = Date(timeIntervalSince1970: 1_000)
    let fetched = LinearIssue(
      id: "uuid-1",
      identifier: "CEN-7404",
      title: "Fix the thing",
      description: "Details",
      stateName: "Todo",
      assigneeName: nil,
      assignedToMe: false,
      url: "https://linear.app/x/issue/CEN-7404"
    )

    var state = LinearInboxFeature.State(availableRepositories: [])
    state.pasteText = "https://linear.app/centrum-ai/issue/CEN-7404/fix-the-thing"

    let store = TestStore(initialState: state) {
      LinearInboxFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.linearClient.fetchIssues = { ids in
        #expect(ids == ["CEN-7404"])
        return [fetched]
      }
    }
    store.exhaustivity = .off

    await store.send(.importTapped(replace: false))
    #expect(store.state.tickets.map(\.identifier) == ["CEN-7404"])
    #expect(store.state.pasteText.isEmpty)
    #expect(store.state.fetchingTicketIDs == ["CEN-7404"])

    await store.receive(\._issuesFetched)
    #expect(store.state.tickets[0].title == "Fix the thing")
    #expect(store.state.tickets[0].summary == "Details")
    #expect(store.state.tickets[0].linearID == "uuid-1")
    #expect(store.state.tickets[0].fetchedAt == now)
    #expect(store.state.fetchingTicketIDs.isEmpty)
  }

  @Test(.dependencies) func taskRefreshesExistingTicketsOnOpen() async {
    resetInbox([LinearTicket(identifier: "CEN-1", title: "Stale", stateType: "started")])
    let now = Date(timeIntervalSince1970: 9_000)
    let fresh = LinearIssue(
      id: "u1",
      identifier: "CEN-1",
      title: "Fresh",
      description: nil,
      stateName: "Done",
      stateType: "completed",
      assigneeName: "me",
      assignedToMe: true,
      url: nil
    )

    let store = TestStore(initialState: LinearInboxFeature.State(availableRepositories: [])) {
      LinearInboxFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.linearClient.fetchIssues = { ids in
        #expect(ids == ["CEN-1"])
        return [fresh]
      }
    }
    store.exhaustivity = .off

    await store.send(.task)
    await store.receive(\._issuesFetched)
    #expect(store.state.tickets[0].title == "Fresh")
    #expect(store.state.tickets[0].isDone)
    #expect(store.state.doneCount == 1)
  }

  @Test(.dependencies) func importReplacePreservesStartedMetadata() async {
    let started = Date(timeIntervalSince1970: 10)
    resetInbox([LinearTicket(identifier: "CEN-1", title: "Old", startedAt: started)])

    var state = LinearInboxFeature.State(availableRepositories: [])
    state.pasteText = "CEN-1 CEN-2"

    let store = TestStore(initialState: state) {
      LinearInboxFeature()
    } withDependencies: {
      $0.date = .constant(Date(timeIntervalSince1970: 50))
      $0.linearClient.fetchIssues = { _ in [] }
    }
    store.exhaustivity = .off

    await store.send(.importTapped(replace: true))
    #expect(store.state.tickets.map(\.identifier) == ["CEN-1", "CEN-2"])
    // The surviving ticket keeps its started marker; the new one has none.
    #expect(store.state.tickets[0].startedAt == started)
    #expect(store.state.tickets[1].startedAt == nil)
  }

  @Test(.dependencies) func startSessionOpensTheNewTerminalTabPrefilled() async {
    resetInbox([LinearTicket(identifier: "CEN-1", title: "Do thing")])

    let store = TestStore(initialState: LinearInboxFeature.State(availableRepositories: [])) {
      LinearInboxFeature()
    }
    store.exhaustivity = .off

    await store.send(.startSessionTapped(ticketID: "CEN-1"))
    #expect(store.state.newTerminal != nil)
    #expect(store.state.newTerminal?.prompt == "Fix CEN-1: Do thing")
    #expect(store.state.selectedTab == .newTerminal)
    #expect(store.state.pendingSessionTicketID == "CEN-1")
  }

  @Test(.dependencies) func spawnDelegateStampsTicketStartedAndForwardsUp() async {
    resetInbox([LinearTicket(identifier: "CEN-1", title: "Do thing")])
    let now = Date(timeIntervalSince1970: 5_000)

    var state = LinearInboxFeature.State(availableRepositories: [])
    state.pendingSessionTicketID = "CEN-1"
    state.selectedTab = .newTerminal
    state.newTerminal = NewTerminalFeature.State(availableRepositories: [])

    let store = TestStore(initialState: state) {
      LinearInboxFeature()
    } withDependencies: {
      $0.date = .constant(now)
    }
    store.exhaustivity = .off

    let session = AgentSession(
      repositoryID: "/tmp/repo",
      worktreeID: "/tmp/repo",
      agent: .claude,
      initialPrompt: "Fix CEN-1"
    )
    await store.send(.newTerminal(.presented(.delegate(.created(session)))))
    #expect(store.state.tickets[0].startedAt == now)
    #expect(store.state.pendingSessionTicketID == nil)
    #expect(store.state.selectedTab == .inbox)

    await store.receive(\.delegate.newTerminalDelegate)
  }

  @Test(.dependencies) func cancelDelegateClosesTheTabWithoutForwarding() async {
    resetInbox([LinearTicket(identifier: "CEN-1", title: "Do thing")])

    var state = LinearInboxFeature.State(availableRepositories: [])
    state.pendingSessionTicketID = "CEN-1"
    state.selectedTab = .newTerminal
    state.newTerminal = NewTerminalFeature.State(availableRepositories: [])

    let store = TestStore(initialState: state) {
      LinearInboxFeature()
    }
    store.exhaustivity = .off

    await store.send(.newTerminal(.presented(.delegate(.cancel))))
    #expect(store.state.newTerminal == nil)
    #expect(store.state.selectedTab == .inbox)
    #expect(store.state.pendingSessionTicketID == nil)
    // No ticket was started — Cancel is not a spawn.
    #expect(store.state.tickets[0].startedAt == nil)
  }

  @Test(.dependencies) func toggleShowDoneFiltersCompletedTickets() async {
    resetInbox([
      LinearTicket(identifier: "CEN-1", title: "Open", stateType: "started"),
      LinearTicket(identifier: "CEN-2", title: "Finished", stateType: "completed"),
      LinearTicket(identifier: "CEN-3", title: "Dropped", stateType: "canceled"),
    ])

    let store = TestStore(initialState: LinearInboxFeature.State(availableRepositories: [])) {
      LinearInboxFeature()
    }
    store.exhaustivity = .off

    // Default hides done — the inbox is a worklist of what's left.
    #expect(store.state.doneCount == 2)
    #expect(store.state.showDone == false)
    #expect(store.state.visibleTickets.map(\.identifier) == ["CEN-1"])

    await store.send(.toggleShowDone)
    #expect(store.state.showDone == true)
    #expect(store.state.visibleTickets.count == 3)

    await store.send(.toggleShowDone)
    #expect(store.state.visibleTickets.map(\.identifier) == ["CEN-1"])
  }

  @Test(.dependencies) func removeTicketDropsItFromTheInbox() async {
    resetInbox([
      LinearTicket(identifier: "CEN-1"),
      LinearTicket(identifier: "CEN-2"),
    ])

    let store = TestStore(initialState: LinearInboxFeature.State(availableRepositories: [])) {
      LinearInboxFeature()
    }
    store.exhaustivity = .off

    await store.send(.removeTicketTapped(ticketID: "CEN-1"))
    #expect(store.state.tickets.map(\.identifier) == ["CEN-2"])
  }
}
