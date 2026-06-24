import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Testing

@testable import Supacool

// MARK: - Ticket id parsing (pure)

struct LinearTicketParsingTests {
  @Test func extractsIDsFromPastedURLsAndBareIDs() {
    let text = """
      https://linear.app/centrum-ai/issue/CEN-7404/the-success-and-failed-status-icons
      https://linear.app/centrum-ai/issue/CEN-7405/when-navigating-to-the-notifications
      Don't forget CEN-7404 (dupe) and ABC-12.
      """
    #expect(linearTicketIDs(in: text) == ["CEN-7404", "CEN-7405", "ABC-12"])
  }

  /// Detection is prefix-agnostic now — team-key scoping lives in the import
  /// and chip-parsing paths, not in raw id extraction.
  @Test func extractsEveryUppercasePrefix() {
    let text = "CEN-1 and ABC-2 and CEN-3"
    #expect(linearTicketIDs(in: text) == ["CEN-1", "ABC-2", "CEN-3"])
  }

  @Test func returnsEmptyWhenNoTickets() {
    #expect(linearTicketIDs(in: "nothing to see").isEmpty)
    #expect(linearTicketIDs(in: "").isEmpty)
  }

  @Test func firstTicketIsTheFirstMatch() {
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

// MARK: - Metadata application (pure)

struct LinearTicketApplyTests {
  @Test func applyCarriesCreatedAtAndCreatorForTheRow() {
    let created = Date(timeIntervalSince1970: 1_700_000_000)
    var ticket = LinearTicket(identifier: "CEN-1")
    #expect(ticket.createdAt == nil)
    #expect(ticket.creatorName == nil)
    ticket.apply(
      LinearIssue(
        id: "u1",
        identifier: "CEN-1",
        title: "T",
        description: nil,
        assigneeName: nil,
        assignedToMe: false,
        creatorName: "Ada Lovelace",
        url: nil,
        createdAt: created
      ),
      fetchedAt: Date(timeIntervalSince1970: 1_700_100_000)
    )
    #expect(ticket.createdAt == created)
    #expect(ticket.creatorName == "Ada Lovelace")
  }

  @Test func isInProgressReflectsStartedStateType() {
    #expect(LinearTicket(identifier: "A-1", stateType: "started").isInProgress)
    #expect(!LinearTicket(identifier: "A-2", stateType: "unstarted").isInProgress)
    #expect(!LinearTicket(identifier: "A-3", stateType: "completed").isInProgress)
    #expect(!LinearTicket(identifier: "A-4").isInProgress)
  }

  @Test func sessionPrimaryTicketPrefersReferenceThenPrompt() {
    func session(prompt: String, references: [SessionReference]) -> AgentSession {
      AgentSession(
        repositoryID: "/tmp/repo",
        worktreeID: "/tmp/repo",
        agent: .claude,
        initialPrompt: prompt,
        references: references
      )
    }
    // A parsed ticket reference wins.
    #expect(session(prompt: "anything", references: [.ticket(id: "CEN-9")]).primaryTicketID == "CEN-9")
    // No references → fall back to the first ticket id in the launch prompt.
    #expect(session(prompt: "Fix CEN-3: do it", references: []).primaryTicketID == "CEN-3")
    // PR reference first, ticket second → the ticket is still primary.
    let mixed = session(
      prompt: "p",
      references: [.pullRequest(owner: "o", repo: "r", number: 1, state: nil, title: nil), .ticket(id: "CEN-7")]
    )
    #expect(mixed.primaryTicketID == "CEN-7")
    // Nothing to link.
    #expect(session(prompt: "no ticket here", references: []).primaryTicketID == nil)
  }
}

// MARK: - Reducer

@MainActor
struct LinearInboxFeatureTests {
  /// The inbox is per-repo; every reducer test triages this one repo, so the
  /// State selects it and `resetInbox` seeds its bucket.
  static let repo = Repository(
    id: "/tmp/repo",
    rootURL: URL(fileURLWithPath: "/tmp/repo"),
    name: "repo",
    worktrees: []
  )

  /// Seeds the repo's bucket and pins the persisted source view. The source is
  /// global `appStorage`, so every test must set it for determinism. Defaults
  /// to `.pasted`, matching the hand-curated tickets most tests seed.
  private func resetInbox(_ tickets: [LinearTicket], source: LinearTicketSource = .pasted) {
    @Shared(.linearInbox) var inbox: [String: [LinearTicket]]
    $inbox.withLock { $0 = [Self.repo.id: tickets] }
    @Shared(.appStorage("linearInboxSource")) var inboxSourceRaw: String = ""
    $inboxSourceRaw.withLock { $0 = source.rawValue }
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

    var state = LinearInboxFeature.State(availableRepositories: [Self.repo])
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

  @Test(.dependencies) func openingInRecentModeAutoFetchesAndRebuildsTheFeed() async {
    let started = Date(timeIntervalSince1970: 10)
    // A pre-existing recent ticket (started) plus a stale recent ticket that
    // has since fallen out of Linear's latest feed.
    resetInbox(
      [
        LinearTicket(identifier: "CEN-1", title: "Stale", source: .recent, startedAt: started),
        LinearTicket(identifier: "CEN-9", title: "Dropped out", source: .recent),
      ],
      source: .recent
    )
    let now = Date(timeIntervalSince1970: 2_000)
    let existing = LinearIssue(
      id: "u1",
      identifier: "CEN-1",
      title: "Fresh title",
      description: "Body",
      stateName: "In Progress",
      stateType: "started",
      assigneeName: "me",
      assignedToMe: true,
      url: nil
    )
    let new = LinearIssue(
      id: "u2",
      identifier: "CEN-2",
      title: "Brand new",
      description: nil,
      stateName: "Todo",
      stateType: "unstarted",
      assigneeName: nil,
      assignedToMe: false,
      url: nil
    )

    let store = TestStore(initialState: LinearInboxFeature.State(availableRepositories: [Self.repo])) {
      LinearInboxFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.linearClient.fetchRecentIssues = { limit, _ in
        #expect(limit == LinearInboxFeature.recentFetchLimit)
        return [existing, new]
      }
    }
    store.exhaustivity = .off

    // Opening in recent mode pulls the feed with no button press.
    await store.send(.task)
    #expect(store.state.isFetchingRecent)

    await store.receive(\._recentIssuesFetched)
    #expect(!store.state.isFetchingRecent)
    // Rebuilt to the feed: CEN-1 survives (keeps started), CEN-2 added,
    // CEN-9 dropped because it's no longer in the latest feed.
    #expect(store.state.tickets.map(\.identifier) == ["CEN-1", "CEN-2"])
    #expect(store.state.tickets[0].title == "Fresh title")
    #expect(store.state.tickets[0].startedAt == started)
    #expect(store.state.tickets[1].title == "Brand new")
    #expect(store.state.tickets[1].linearID == "u2")
    #expect(store.state.tickets[1].fetchedAt == now)
  }

  @Test(.dependencies) func recentFetchLeavesThePastedSetUntouched() async {
    // A pasted ticket and a recent ticket sharing the bucket. The recent feed
    // returns the pasted id too, but it must stay pasted (no duplicate).
    resetInbox(
      [
        LinearTicket(identifier: "CEN-1", title: "Curated", source: .pasted),
        LinearTicket(identifier: "CEN-2", title: "Old recent", source: .recent),
      ],
      source: .recent
    )
    let now = Date(timeIntervalSince1970: 3_000)

    let store = TestStore(initialState: LinearInboxFeature.State(availableRepositories: [Self.repo])) {
      LinearInboxFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.linearClient.fetchRecentIssues = { _, _ in
        [
          LinearIssue(
            id: "u1", identifier: "CEN-1", title: "Curated", description: nil,
            assigneeName: nil, assignedToMe: false, url: nil
          ),
          LinearIssue(
            id: "u3", identifier: "CEN-3", title: "New recent", description: nil,
            assigneeName: nil, assignedToMe: false, url: nil
          ),
        ]
      }
    }
    store.exhaustivity = .off

    await store.send(.fetchRecentTapped)
    await store.receive(\._recentIssuesFetched)
    // Recent view shows only the feed minus the curated id: CEN-3 (CEN-1 stays
    // pasted, CEN-2 fell out).
    #expect(store.state.tickets.map(\.identifier) == ["CEN-3"])
    // The pasted ticket is still in the bucket under the Pasted source.
    #expect(store.state.bucket.contains { $0.identifier == "CEN-1" && $0.source == .pasted })
  }

  @Test(.dependencies) func fetchRecentFailureSurfacesTheError() async {
    resetInbox([], source: .recent)

    let store = TestStore(initialState: LinearInboxFeature.State(availableRepositories: [Self.repo])) {
      LinearInboxFeature()
    } withDependencies: {
      $0.linearClient.fetchRecentIssues = { _, _ in throw LinearClientError.missingAPIKey }
    }
    store.exhaustivity = .off

    await store.send(.fetchRecentTapped)
    await store.receive(\._fetchFailed)
    #expect(!store.state.isFetchingRecent)
    #expect(store.state.errorMessage?.contains("API key") == true)
    #expect(store.state.tickets.isEmpty)
  }

  @Test(.dependencies) func fetchRecentWithoutTeamScopePromptsForConfiguration() async {
    resetInbox([], source: .recent)

    let store = TestStore(initialState: LinearInboxFeature.State(availableRepositories: [Self.repo])) {
      LinearInboxFeature()
    } withDependencies: {
      $0.linearClient.fetchRecentIssues = { _, _ in throw LinearClientError.missingTeamScope }
    }
    store.exhaustivity = .off

    await store.send(.fetchRecentTapped)
    await store.receive(\._fetchFailed)
    #expect(!store.state.isFetchingRecent)
    #expect(store.state.errorMessage?.contains("Linear team key") == true)
    #expect(store.state.tickets.isEmpty)
  }

  @Test(.dependencies) func fetchRecentWithNoResultsExplainsItself() async {
    resetInbox([], source: .recent)

    let store = TestStore(initialState: LinearInboxFeature.State(availableRepositories: [Self.repo])) {
      LinearInboxFeature()
    } withDependencies: {
      $0.linearClient.fetchRecentIssues = { _, _ in [] }
    }
    store.exhaustivity = .off

    await store.send(.fetchRecentTapped)
    await store.receive(\._recentIssuesFetched)
    #expect(!store.state.isFetchingRecent)
    #expect(store.state.errorMessage == "No recently created tickets found in Linear.")
  }

  @Test(.dependencies) func switchingToPastedShowsTheCuratedSetAndRefreshesIt() async {
    resetInbox(
      [
        LinearTicket(identifier: "CEN-1", title: "Recent one", source: .recent),
        LinearTicket(identifier: "CEN-5", title: "Curated", source: .pasted),
      ],
      source: .recent
    )

    let store = TestStore(initialState: LinearInboxFeature.State(availableRepositories: [Self.repo])) {
      LinearInboxFeature()
    } withDependencies: {
      $0.date = .constant(Date(timeIntervalSince1970: 1))
      $0.linearClient.fetchIssues = { ids in
        // Switching to pasted refreshes only the pasted ids.
        #expect(ids == ["CEN-5"])
        return []
      }
    }
    store.exhaustivity = .off

    #expect(store.state.tickets.map(\.identifier) == ["CEN-1"])
    await store.send(.sourceChanged(.pasted))
    #expect(store.state.source == .pasted)
    #expect(store.state.tickets.map(\.identifier) == ["CEN-5"])
    await store.receive(\._issuesFetched)
  }

  @Test(.dependencies) func assignedToMeFilterNarrowsToYourTickets() async {
    resetInbox([
      LinearTicket(identifier: "CEN-1", title: "Mine", assignedToMe: true),
      LinearTicket(identifier: "CEN-2", title: "Theirs", assigneeName: "Someone"),
    ])

    let store = TestStore(initialState: LinearInboxFeature.State(availableRepositories: [Self.repo])) {
      LinearInboxFeature()
    }
    store.exhaustivity = .off

    #expect(store.state.assignedToMeCount == 1)
    #expect(store.state.visibleTickets.map(\.identifier) == ["CEN-1", "CEN-2"])

    await store.send(.toggleAssignedToMe)
    #expect(store.state.assignedToMeOnly)
    #expect(store.state.visibleTickets.map(\.identifier) == ["CEN-1"])
  }

  @Test(.dependencies) func bundlesSiblingSubIssuesUnderOneGroup() {
    // Three siblings under CEN-100 collapse into a group; the lone child of
    // CEN-200 stays a plain row; the standalone ticket is untouched. Order
    // follows the bucket, with the group pinned to its first child.
    resetInbox([
      LinearTicket(identifier: "CEN-1", title: "Standalone"),
      LinearTicket(identifier: "CEN-101", title: "Doc A", parentIdentifier: "CEN-100", parentTitle: "Help docs"),
      LinearTicket(identifier: "CEN-102", title: "Doc B", parentIdentifier: "CEN-100", parentTitle: "Help docs"),
      LinearTicket(identifier: "CEN-103", title: "Doc C", parentIdentifier: "CEN-100", parentTitle: "Help docs"),
      LinearTicket(identifier: "CEN-201", title: "Lone child", parentIdentifier: "CEN-200", parentTitle: "Other"),
    ])
    let state = LinearInboxFeature.State(availableRepositories: [Self.repo])

    #expect(state.visibleEntries.map(\.id) == ["ticket:CEN-1", "group:CEN-100", "ticket:CEN-201"])

    guard case .group(let group) = state.visibleEntries[1] else {
      Issue.record("expected a group at index 1")
      return
    }
    #expect(group.parentTitle == "Help docs")
    #expect(group.children.map(\.identifier) == ["CEN-101", "CEN-102", "CEN-103"])
  }

  @Test(.dependencies) func toggleGroupExpandedFlipsMembership() async {
    resetInbox([
      LinearTicket(identifier: "CEN-101", parentIdentifier: "CEN-100"),
      LinearTicket(identifier: "CEN-102", parentIdentifier: "CEN-100"),
    ])
    let store = TestStore(initialState: LinearInboxFeature.State(availableRepositories: [Self.repo])) {
      LinearInboxFeature()
    }
    store.exhaustivity = .off

    await store.send(.toggleGroupExpanded(parentID: "CEN-100")) {
      $0.expandedGroupIDs = ["CEN-100"]
    }
    await store.send(.toggleGroupExpanded(parentID: "CEN-100")) {
      $0.expandedGroupIDs = []
    }
  }

  @Test(.dependencies) func linksAndOpensSessionDiscoveredByTicketReference() async {
    // The ticket was never started from the inbox (no startedSessionID), but a
    // live board session references it — the inbox should link them up.
    resetInbox([LinearTicket(identifier: "CEN-1", title: "Do thing")])
    let session = AgentSession(
      repositoryID: "/tmp/repo",
      worktreeID: "/tmp/repo",
      agent: .claude,
      initialPrompt: "Fix CEN-1: Do thing",
      references: [.ticket(id: "CEN-1")]
    )
    @Shared(.agentSessions) var sessions: [AgentSession]
    $sessions.withLock { $0 = [session] }

    let store = TestStore(initialState: LinearInboxFeature.State(availableRepositories: [Self.repo])) {
      LinearInboxFeature()
    }
    store.exhaustivity = .off

    #expect(store.state.tickets[0].startedSessionID == nil)
    #expect(store.state.liveLinkedSessionID(for: store.state.tickets[0]) == session.id)
    #expect(store.state.linkedCount == 1)

    await store.send(.openSessionTapped(ticketID: "CEN-1"))
    await store.receive(\.delegate.openSession)
  }

  @Test(.dependencies) func hideLinkedFilterDropsTicketsWithASession() async {
    resetInbox([
      LinearTicket(identifier: "CEN-1", title: "Linked"),
      LinearTicket(identifier: "CEN-2", title: "Unlinked"),
    ])
    let session = AgentSession(
      repositoryID: "/tmp/repo",
      worktreeID: "/tmp/repo",
      agent: .claude,
      initialPrompt: "Fix CEN-1",
      references: [.ticket(id: "CEN-1")]
    )
    @Shared(.agentSessions) var sessions: [AgentSession]
    $sessions.withLock { $0 = [session] }

    let store = TestStore(initialState: LinearInboxFeature.State(availableRepositories: [Self.repo])) {
      LinearInboxFeature()
    }
    store.exhaustivity = .off

    #expect(store.state.linkedCount == 1)
    #expect(store.state.visibleTickets.map(\.identifier) == ["CEN-1", "CEN-2"])

    await store.send(.toggleHideLinked)
    #expect(store.state.hideLinked)
    #expect(store.state.visibleTickets.map(\.identifier) == ["CEN-2"])
  }

  @Test(.dependencies) func hideInProgressFilterDropsStartedTickets() async {
    resetInbox([
      LinearTicket(identifier: "CEN-1", title: "Todo", stateType: "unstarted"),
      LinearTicket(identifier: "CEN-2", title: "Working", stateType: "started"),
      LinearTicket(identifier: "CEN-3", title: "Reviewing", stateType: "started"),
    ])

    let store = TestStore(initialState: LinearInboxFeature.State(availableRepositories: [Self.repo])) {
      LinearInboxFeature()
    }
    store.exhaustivity = .off

    #expect(store.state.inProgressCount == 2)
    #expect(store.state.visibleTickets.map(\.identifier) == ["CEN-1", "CEN-2", "CEN-3"])

    await store.send(.toggleHideInProgress)
    #expect(store.state.hideInProgress)
    // Both the in-progress and in-review tickets drop out.
    #expect(store.state.visibleTickets.map(\.identifier) == ["CEN-1"])
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

    let store = TestStore(initialState: LinearInboxFeature.State(availableRepositories: [Self.repo])) {
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

    var state = LinearInboxFeature.State(availableRepositories: [Self.repo])
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

    let store = TestStore(initialState: LinearInboxFeature.State(availableRepositories: [Self.repo])) {
      LinearInboxFeature()
    }
    store.exhaustivity = .off

    await store.send(.startSessionTapped(ticketID: "CEN-1"))
    #expect(store.state.newTerminal != nil)
    #expect(store.state.newTerminal?.prompt == "Fix CEN-1: Do thing")
    #expect(store.state.selectedTab == .newTerminal)
    #expect(store.state.pendingSessionTicketID == "CEN-1")
    // The known title arms the worktree exactly like typing the ticket id
    // into the New Terminal screen would.
    #expect(store.state.newTerminal?.workspaceQuery == "cen-1-do-thing")
    #expect(store.state.newTerminal?.selectedWorkspace == .newBranch(name: "cen-1-do-thing"))
  }

  @Test(.dependencies) func startSessionWithoutTitleLeavesWorkspaceUntouched() async {
    resetInbox([LinearTicket(identifier: "CEN-2")])

    let store = TestStore(initialState: LinearInboxFeature.State(availableRepositories: [Self.repo])) {
      LinearInboxFeature()
    }
    store.exhaustivity = .off

    await store.send(.startSessionTapped(ticketID: "CEN-2"))
    #expect(store.state.newTerminal?.prompt == "Fix CEN-2")
    // No title yet — nothing to derive a branch name from.
    #expect(store.state.newTerminal?.workspaceQuery.isEmpty == true)
  }

  @Test(.dependencies) func spawnDelegateStampsTicketStartedAndForwardsUp() async {
    resetInbox([LinearTicket(identifier: "CEN-1", title: "Do thing")])
    let now = Date(timeIntervalSince1970: 5_000)

    var state = LinearInboxFeature.State(availableRepositories: [Self.repo])
    state.pendingSessionTicketID = "CEN-1"
    state.selectedTab = .newTerminal
    state.expandedTicketIDs = ["CEN-1"]
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
    #expect(store.state.tickets[0].startedSessionID == session.id)
    #expect(store.state.pendingSessionTicketID == nil)
    #expect(store.state.selectedTab == .inbox)
    // The submitted ticket collapses so the list visibly reacts.
    #expect(!store.state.expandedTicketIDs.contains("CEN-1"))

    await store.receive(\.delegate.newTerminalDelegate)
  }

  @Test(.dependencies) func spawnAutoAssignsAndMovesTicketToInProgress() async {
    resetInbox([
      LinearTicket(identifier: "CEN-1", linearID: "u1", title: "Do thing", stateName: "Backlog", stateType: "backlog")
    ])
    let now = Date(timeIntervalSince1970: 5_000)

    var state = LinearInboxFeature.State(availableRepositories: [Self.repo])
    state.pendingSessionTicketID = "CEN-1"
    state.selectedTab = .newTerminal
    state.newTerminal = NewTerminalFeature.State(availableRepositories: [])

    let synced = LinearIssue(
      id: "u1",
      identifier: "CEN-1",
      title: "Do thing",
      description: nil,
      stateName: "In Progress",
      stateType: "started",
      assigneeName: "me",
      assignedToMe: true,
      url: nil
    )

    let store = TestStore(initialState: state) {
      LinearInboxFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.linearClient.assignToMe = { id in
        #expect(id == "u1")
        return synced
      }
      $0.linearClient.startProgress = { id in
        #expect(id == "u1")
        return synced
      }
    }
    store.exhaustivity = .off

    let session = AgentSession(
      repositoryID: "/tmp/repo",
      worktreeID: "/tmp/repo",
      agent: .claude,
      initialPrompt: "Fix CEN-1"
    )
    await store.send(.newTerminal(.presented(.delegate(.created(session)))))
    // Optimistic: the row flips before Linear answers.
    #expect(store.state.tickets[0].assignedToMe)
    #expect(store.state.tickets[0].stateType == "started")
    #expect(store.state.tickets[0].stateName == "In Progress")

    await store.receive(\._inProgressSyncCompleted)
    #expect(store.state.tickets[0].assignedToMe)
    #expect(store.state.tickets[0].isInProgress)
    #expect(store.state.tickets[0].startedAt == now)
  }

  @Test(.dependencies) func spawnRevertsOptimisticStatusWhenLinearRejectsIt() async {
    resetInbox([
      LinearTicket(identifier: "CEN-1", linearID: "u1", title: "Do thing", stateName: "Backlog", stateType: "backlog")
    ])
    let now = Date(timeIntervalSince1970: 5_000)

    var state = LinearInboxFeature.State(availableRepositories: [Self.repo])
    state.pendingSessionTicketID = "CEN-1"
    state.selectedTab = .newTerminal
    state.newTerminal = NewTerminalFeature.State(availableRepositories: [])

    let store = TestStore(initialState: state) {
      LinearInboxFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.linearClient.assignToMe = { _ in throw LinearClientError.unauthorized }
    }
    store.exhaustivity = .off

    let session = AgentSession(
      repositoryID: "/tmp/repo",
      worktreeID: "/tmp/repo",
      agent: .claude,
      initialPrompt: "Fix CEN-1"
    )
    await store.send(.newTerminal(.presented(.delegate(.created(session)))))
    #expect(store.state.tickets[0].assignedToMe)
    #expect(store.state.tickets[0].stateType == "started")

    await store.receive(\._inProgressSyncFailed)
    // Reverted to the pre-spawn Linear status…
    #expect(!store.state.tickets[0].assignedToMe)
    #expect(store.state.tickets[0].stateName == "Backlog")
    #expect(store.state.tickets[0].stateType == "backlog")
    #expect(store.state.errorMessage != nil)
    // …but the local "started" stamp survives — the session did launch.
    #expect(store.state.tickets[0].startedAt == now)
  }

  @Test(.dependencies) func openSessionDelegatesWhenTheSessionStillLives() async {
    let session = AgentSession(
      repositoryID: "/tmp/repo",
      worktreeID: "/tmp/repo",
      agent: .claude,
      initialPrompt: "Fix CEN-1"
    )
    resetInbox([
      LinearTicket(identifier: "CEN-1", title: "Do thing", startedAt: Date(), startedSessionID: session.id)
    ])
    @Shared(.agentSessions) var sessions: [AgentSession]
    $sessions.withLock { $0 = [session] }

    let store = TestStore(initialState: LinearInboxFeature.State(availableRepositories: [Self.repo])) {
      LinearInboxFeature()
    }
    store.exhaustivity = .off

    await store.send(.openSessionTapped(ticketID: "CEN-1"))
    await store.receive(\.delegate.openSession)
  }

  @Test(.dependencies) func openSessionIsANoOpWhenTheSessionWasDeleted() async {
    resetInbox([
      LinearTicket(identifier: "CEN-1", title: "Do thing", startedAt: Date(), startedSessionID: UUID())
    ])
    @Shared(.agentSessions) var sessions: [AgentSession]
    $sessions.withLock { $0 = [] }

    let store = TestStore(initialState: LinearInboxFeature.State(availableRepositories: [Self.repo])) {
      LinearInboxFeature()
    }

    // Exhaustive: no delegate (or any other action) may follow.
    await store.send(.openSessionTapped(ticketID: "CEN-1"))
  }

  @Test(.dependencies) func cancelDelegateClosesTheTabWithoutForwarding() async {
    resetInbox([LinearTicket(identifier: "CEN-1", title: "Do thing")])

    var state = LinearInboxFeature.State(availableRepositories: [Self.repo])
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

    let store = TestStore(initialState: LinearInboxFeature.State(availableRepositories: [Self.repo])) {
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

  @Test(.dependencies) func openingTheInboxDropsTicketsDoneLongerThanRetention() async {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let fourDaysAgo = now.addingTimeInterval(-4 * 24 * 60 * 60)
    let oneDayAgo = now.addingTimeInterval(-1 * 24 * 60 * 60)
    resetInbox([
      LinearTicket(identifier: "CEN-1", stateType: "completed", doneAt: fourDaysAgo),
      LinearTicket(identifier: "CEN-2", stateType: "completed", doneAt: oneDayAgo),
      // Done but with no known timestamp yet — kept until a fetch stamps it.
      LinearTicket(identifier: "CEN-3", stateType: "canceled"),
      LinearTicket(identifier: "CEN-4", stateType: "started", doneAt: fourDaysAgo),
    ])

    let store = TestStore(initialState: LinearInboxFeature.State(availableRepositories: [Self.repo])) {
      LinearInboxFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.linearClient.fetchIssues = { ids in
        // The expired ticket is gone before the refresh fires.
        #expect(ids == ["CEN-2", "CEN-3", "CEN-4"])
        return []
      }
    }
    store.exhaustivity = .off

    await store.send(.task)
    #expect(store.state.tickets.map(\.identifier) == ["CEN-2", "CEN-3", "CEN-4"])
  }

  @Test(.dependencies) func fetchStampsDoneAtAndAgesOutOldDoneTickets() async {
    resetInbox([LinearTicket(identifier: "CEN-1", title: "Old", stateType: "started")])
    let now = Date(timeIntervalSince1970: 2_000_000)
    let completedFiveDaysAgo = LinearIssue(
      id: "u1",
      identifier: "CEN-1",
      title: "Old",
      description: nil,
      stateName: "Done",
      stateType: "completed",
      assigneeName: nil,
      assignedToMe: false,
      url: nil,
      completedAt: now.addingTimeInterval(-5 * 24 * 60 * 60)
    )

    let store = TestStore(initialState: LinearInboxFeature.State(availableRepositories: [Self.repo])) {
      LinearInboxFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.linearClient.fetchIssues = { _ in [completedFiveDaysAgo] }
    }
    store.exhaustivity = .off

    await store.send(.task)
    await store.receive(\._issuesFetched)
    // Linear says it was finished five days ago — gone immediately.
    #expect(store.state.tickets.isEmpty)
  }

  @Test(.dependencies) func toggleIgnoreHidesTheTicketWithoutRemovingIt() async {
    resetInbox([
      LinearTicket(identifier: "CEN-1", title: "Keep"),
      LinearTicket(identifier: "CEN-2", title: "Ignore me"),
    ])

    let store = TestStore(initialState: LinearInboxFeature.State(availableRepositories: [Self.repo])) {
      LinearInboxFeature()
    }
    store.exhaustivity = .off

    await store.send(.toggleIgnoreTapped(ticketID: "CEN-2"))
    // Still in the inbox, just not on the worklist.
    #expect(store.state.tickets.map(\.identifier) == ["CEN-1", "CEN-2"])
    #expect(store.state.visibleTickets.map(\.identifier) == ["CEN-1"])
    #expect(store.state.ignoredCount == 1)

    // The "Ignored" filter reveals ignored rows…
    await store.send(.toggleShowIgnored)
    #expect(store.state.visibleTickets.map(\.identifier) == ["CEN-1", "CEN-2"])

    // …and an ignored ticket can be brought back.
    await store.send(.toggleIgnoreTapped(ticketID: "CEN-2"))
    await store.send(.toggleShowIgnored)
    #expect(store.state.visibleTickets.map(\.identifier) == ["CEN-1", "CEN-2"])
    #expect(store.state.ignoredCount == 0)
  }

  @Test(.dependencies) func removeTicketDropsItFromTheInbox() async {
    resetInbox([
      LinearTicket(identifier: "CEN-1"),
      LinearTicket(identifier: "CEN-2"),
    ])

    let store = TestStore(initialState: LinearInboxFeature.State(availableRepositories: [Self.repo])) {
      LinearInboxFeature()
    }
    store.exhaustivity = .off

    await store.send(.removeTicketTapped(ticketID: "CEN-1"))
    #expect(store.state.tickets.map(\.identifier) == ["CEN-2"])
  }
}
