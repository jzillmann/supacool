import ComposableArchitecture
import Foundation

/// The Linear Inbox: paste a list of Linear ticket URLs, get a persistent,
/// refreshable overview, and kick off a coding session on any of them.
///
/// The "start session" flow embeds `NewTerminalFeature` as a presented
/// child rendered as a **second tab** (not a stacked sheet) so the user
/// never juggles two overlapping dialogs. The embedded sheet's spawn
/// delegates bubble up to `BoardFeature` — which owns session creation —
/// via `Delegate.newTerminalDelegate`.
@Reducer
struct LinearInboxFeature {
  @ObservableState
  struct State: Equatable {
    /// Persisted list of pasted tickets. Survives relaunch.
    @Shared(.linearInbox) var tickets: [LinearTicket] = []

    /// Live-synced by BoardFeature so the embedded New Terminal tab's
    /// repo picker stays current with repos added/removed while open.
    var availableRepositories: IdentifiedArrayOf<Repository>

    /// Free-text in the import field (pasted URLs / ids).
    var pasteText: String = ""
    var selectedTab: Tab = .inbox
    /// When false (the default), tickets in a completed/canceled Linear
    /// state are hidden so the inbox reads as a worklist of what's left.
    var showDone: Bool = false
    /// Rows currently showing their description.
    var expandedTicketIDs: Set<String> = []
    /// Ids with an in-flight metadata fetch.
    var fetchingTicketIDs: Set<String> = []
    /// Ids with an in-flight assign-to-me mutation.
    var assigningTicketIDs: Set<String> = []
    var errorMessage: String?

    /// The ticket whose session is being configured in the embedded tab.
    /// Used to stamp `startedAt` once the spawn fires.
    var pendingSessionTicketID: String?

    @Presents var newTerminal: NewTerminalFeature.State?

    init(availableRepositories: IdentifiedArrayOf<Repository>) {
      self.availableRepositories = availableRepositories
    }

    var hasNewTerminalTab: Bool { newTerminal != nil }

    /// Number of tickets Linear reports as done (completed/canceled).
    var doneCount: Int { tickets.filter(\.isDone).count }

    /// Tickets shown in the list, honoring the show/hide-done toggle.
    var visibleTickets: [LinearTicket] {
      showDone ? Array(tickets) : tickets.filter { !$0.isDone }
    }
  }

  nonisolated enum Tab: String, Equatable, Sendable, CaseIterable {
    case inbox
    case newTerminal
  }

  enum Action: BindableAction, Equatable {
    case binding(BindingAction<State>)
    /// Sheet appeared — refresh any tickets we already have.
    case task
    /// Import the pasted text. `replace: true` rebuilds the list (keeping
    /// metadata for surviving ids); `false` appends new ids only.
    case importTapped(replace: Bool)
    case refreshAllTapped
    case toggleExpanded(ticketID: String)
    case assignToMeTapped(ticketID: String)
    case startSessionTapped(ticketID: String)
    case removeTicketTapped(ticketID: String)
    case toggleShowDone
    case clearError
    case closeTapped

    case _issuesFetched([LinearIssue])
    case _fetchFailed(message: String)
    case _assignCompleted(ticketID: String, LinearIssue?)
    case _assignFailed(ticketID: String, message: String)

    case newTerminal(PresentationAction<NewTerminalFeature.Action>)
    case delegate(Delegate)

    @CasePathable
    enum Delegate: Equatable {
      /// Bubble the embedded New Terminal sheet's delegate up to
      /// BoardFeature, which owns spawning, bookmarks and drafts.
      case newTerminalDelegate(NewTerminalFeature.Action.Delegate)
    }
  }

  @Dependency(LinearClient.self) var linearClient
  @Dependency(\.date) var date
  @Dependency(\.dismiss) var dismiss

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .task:
        let ids = state.tickets.map(\.identifier)
        guard !ids.isEmpty else { return .none }
        state.fetchingTicketIDs = Set(ids)
        return fetchIssues(ids: ids)

      case let .importTapped(replace):
        let ids = linearTicketIDs(in: state.pasteText)
        guard !ids.isEmpty else {
          state.errorMessage = "No Linear ticket links found in the pasted text."
          return .none
        }
        let now = date.now
        state.$tickets.withLock { tickets in
          if replace {
            // Preserve inbox-local metadata for ids that survive the
            // replace so "started" markers don't reset.
            let existing = Dictionary(tickets.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
            tickets = ids.map { existing[$0] ?? LinearTicket(identifier: $0, addedAt: now) }
          } else {
            for id in ids where !tickets.contains(where: { $0.identifier == id }) {
              tickets.append(LinearTicket(identifier: id, addedAt: now))
            }
          }
        }
        state.pasteText = ""
        state.errorMessage = nil
        state.fetchingTicketIDs = Set(ids)
        return fetchIssues(ids: ids)

      case .refreshAllTapped:
        let ids = state.tickets.map(\.identifier)
        guard !ids.isEmpty else { return .none }
        state.fetchingTicketIDs = Set(ids)
        state.errorMessage = nil
        return fetchIssues(ids: ids)

      case let .toggleExpanded(ticketID):
        if state.expandedTicketIDs.contains(ticketID) {
          state.expandedTicketIDs.remove(ticketID)
        } else {
          state.expandedTicketIDs.insert(ticketID)
        }
        return .none

      case let .assignToMeTapped(ticketID):
        guard let ticket = state.tickets.first(where: { $0.identifier == ticketID }) else {
          return .none
        }
        guard let linearID = ticket.linearID else {
          // We need the internal UUID (only known after a fetch) to assign.
          state.errorMessage = "Still loading \(ticketID) — try again in a moment."
          return .none
        }
        state.assigningTicketIDs.insert(ticketID)
        state.errorMessage = nil
        return .run { send in
          do {
            let updated = try await linearClient.assignToMe(linearID)
            await send(._assignCompleted(ticketID: ticketID, updated))
          } catch {
            await send(._assignFailed(ticketID: ticketID, message: error.localizedDescription))
          }
        }

      case let .startSessionTapped(ticketID):
        guard let ticket = state.tickets.first(where: { $0.identifier == ticketID }) else {
          return .none
        }
        state.pendingSessionTicketID = ticketID
        var newTerminal = NewTerminalFeature.State(availableRepositories: state.availableRepositories)
        newTerminal.prompt = ticket.sessionPrompt
        state.newTerminal = newTerminal
        state.selectedTab = .newTerminal
        return .none

      case let .removeTicketTapped(ticketID):
        state.$tickets.withLock { $0.removeAll { $0.identifier == ticketID } }
        state.expandedTicketIDs.remove(ticketID)
        return .none

      case .toggleShowDone:
        state.showDone.toggle()
        return .none

      case .clearError:
        state.errorMessage = nil
        return .none

      case .closeTapped:
        return .run { _ in await dismiss() }

      case let ._issuesFetched(issues):
        let now = date.now
        let byID = Dictionary(issues.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        state.$tickets.withLock { tickets in
          for index in tickets.indices {
            if let issue = byID[tickets[index].identifier] {
              tickets[index].apply(issue, fetchedAt: now)
            }
          }
        }
        // One batch fetch resolves the whole in-flight set.
        state.fetchingTicketIDs = []
        return .none

      case let ._fetchFailed(message):
        state.fetchingTicketIDs = []
        state.errorMessage = message
        return .none

      case let ._assignCompleted(ticketID, issue):
        state.assigningTicketIDs.remove(ticketID)
        let now = date.now
        state.$tickets.withLock { tickets in
          guard let index = tickets.firstIndex(where: { $0.identifier == ticketID }) else { return }
          if let issue {
            tickets[index].apply(issue, fetchedAt: now)
          } else {
            // Mutation succeeded but returned no issue — reflect intent.
            tickets[index].assignedToMe = true
          }
        }
        return .none

      case let ._assignFailed(ticketID, message):
        state.assigningTicketIDs.remove(ticketID)
        state.errorMessage = message
        return .none

      case let .newTerminal(.presented(.delegate(inner))):
        switch inner {
        case .cancel:
          // Close the embedded tab and return to the inbox; nothing spawned.
          state.newTerminal = nil
          state.selectedTab = .inbox
          state.pendingSessionTicketID = nil
          return .none
        case .spawnRequested, .created:
          // Stamp the originating ticket as started, then hand the spawn
          // to BoardFeature (it closes the tab and owns the lifecycle).
          if let ticketID = state.pendingSessionTicketID {
            let now = date.now
            state.$tickets.withLock { tickets in
              if let index = tickets.firstIndex(where: { $0.identifier == ticketID }) {
                tickets[index].startedAt = now
              }
            }
          }
          state.pendingSessionTicketID = nil
          state.selectedTab = .inbox
          return .send(.delegate(.newTerminalDelegate(inner)))
        case .bookmarkSaved, .draftSaved, .draftConsumed:
          // Let BoardFeature persist these as usual.
          return .send(.delegate(.newTerminalDelegate(inner)))
        }

      case .newTerminal:
        return .none

      case .delegate:
        return .none
      }
    }
    .ifLet(\.$newTerminal, action: \.newTerminal) {
      NewTerminalFeature()
    }
  }

  private func fetchIssues(ids: [String]) -> Effect<Action> {
    .run { send in
      do {
        let issues = try await linearClient.fetchIssues(ids)
        await send(._issuesFetched(issues))
      } catch {
        await send(._fetchFailed(message: error.localizedDescription))
      }
    }
  }
}
