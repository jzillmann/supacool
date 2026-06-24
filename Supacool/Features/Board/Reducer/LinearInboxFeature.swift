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
    /// Persisted tickets, bucketed per repository. Survives relaunch. Each
    /// bucket holds both the auto-fetched **recent** set and the hand-curated
    /// **pasted** set, tagged by `LinearTicket.source`; ``tickets`` exposes
    /// only the selected repo + selected source.
    @Shared(.linearInbox) var inbox: [String: [LinearTicket]] = [:]

    /// The selected source view (recent vs pasted), persisted so reopening the
    /// inbox restores the same view. Stored as a raw string because
    /// `@Shared(.appStorage(...))` bridges scalars more reliably than enums.
    // Dot-free key: dotted keys break efficient cross-process KVO (matters for
    // the isolated preview instance), matching `prPulseIgnoredPRKeys` etc.
    @Shared(.appStorage("linearInboxSource"))
    var inboxSourceRaw: String = LinearTicketSource.recent.rawValue

    /// Live board sessions — read-only here. Lets a started ticket offer
    /// "Open session" instead of spawning a duplicate, and lets the row
    /// fall back to "Start session" when the session was deleted.
    @Shared(.agentSessions) var sessions: [AgentSession] = []

    /// Live-synced by BoardFeature so the embedded New Terminal tab's
    /// repo picker stays current with repos added/removed while open.
    var availableRepositories: IdentifiedArrayOf<Repository>

    /// The repository whose worklist is on screen. The inbox is per-repo, so
    /// every ticket mutation and the recent-ticket import scope to this repo.
    var selectedRepositoryID: Repository.ID?

    /// Free-text in the import field (pasted URLs / ids).
    var pasteText: String = ""
    var selectedTab: Tab = .inbox
    /// When false (the default), tickets in a completed/canceled Linear
    /// state are hidden so the inbox reads as a worklist of what's left.
    var showDone: Bool = false
    /// When false (the default), ignored tickets are hidden from the worklist.
    var showIgnored: Bool = false
    /// When true, only tickets assigned to the API-key holder are shown.
    var assignedToMeOnly: Bool = false
    /// When true, tickets already in progress / in review are hidden, so the
    /// worklist surfaces only work that hasn't been picked up yet.
    var hideInProgress: Bool = false
    /// When true, tickets that already have a live board session are hidden.
    var hideLinked: Bool = false
    /// Rows currently showing their description.
    var expandedTicketIDs: Set<String> = []
    /// Parent groups currently expanded to reveal their bundled sub-issues.
    var expandedGroupIDs: Set<String> = []
    /// Ids with an in-flight metadata fetch.
    var fetchingTicketIDs: Set<String> = []
    /// True while the "last N created" import is in flight.
    var isFetchingRecent: Bool = false
    /// Ids with an in-flight assign-to-me mutation.
    var assigningTicketIDs: Set<String> = []
    var errorMessage: String?

    /// The ticket whose session is being configured in the embedded tab.
    /// Used to stamp `startedAt` once the spawn fires.
    var pendingSessionTicketID: String?

    @Presents var newTerminal: NewTerminalFeature.State?

    init(
      availableRepositories: IdentifiedArrayOf<Repository>,
      selectedRepositoryID: Repository.ID? = nil
    ) {
      self.availableRepositories = availableRepositories
      self.selectedRepositoryID = selectedRepositoryID ?? availableRepositories.first?.id
    }

    var hasNewTerminalTab: Bool { newTerminal != nil }

    /// The selected source view (recent vs pasted).
    var source: LinearTicketSource {
      LinearTicketSource(rawValue: inboxSourceRaw) ?? .recent
    }

    /// The repository whose worklist is on screen.
    var selectedRepository: Repository? {
      guard let selectedRepositoryID else { return nil }
      return availableRepositories[id: selectedRepositoryID]
    }

    /// The selected repo's full bucket (both sources). Internal — the reducer
    /// mutates this via `mutateSelectedTickets`.
    var bucket: [LinearTicket] {
      guard let selectedRepositoryID else { return [] }
      return inbox[selectedRepositoryID] ?? []
    }

    /// The selected repo's tickets for the **selected source**. Read-only —
    /// mutate through `mutateSelectedTickets`.
    var tickets: [LinearTicket] {
      bucket.filter { $0.source == source }
    }

    /// Number of tickets Linear reports as done (completed/canceled).
    var doneCount: Int { tickets.filter(\.isDone).count }

    /// Number of tickets the user ignored.
    var ignoredCount: Int { tickets.filter(\.isHidden).count }

    /// Number of tickets assigned to the API-key holder.
    var assignedToMeCount: Int { tickets.filter(\.assignedToMe).count }

    /// Number of tickets actively in progress / in review.
    var inProgressCount: Int { tickets.filter(\.isInProgress).count }

    /// Number of tickets linked to a live board session.
    var linkedCount: Int { tickets.filter { liveLinkedSessionID(for: $0) != nil }.count }

    /// Tickets shown in the list, after the quick filters. Done, ignored and
    /// linked tickets are hidden unless their filter says otherwise;
    /// "assigned to me" and "hide in progress" narrow further.
    var visibleTickets: [LinearTicket] {
      tickets.filter { ticket in
        if assignedToMeOnly, !ticket.assignedToMe { return false }
        if hideInProgress, ticket.isInProgress { return false }
        if hideLinked, liveLinkedSessionID(for: ticket) != nil { return false }
        if !showDone, ticket.isDone { return false }
        if !showIgnored, ticket.isHidden { return false }
        return true
      }
    }

    /// The visible worklist folded into display rows: a sub-issue whose parent
    /// has 2+ visible siblings collapses into a `.group`; everything else stays
    /// a standalone `.ticket`. Order follows ``visibleTickets``, with each group
    /// pinned to where its first child appears. Single-child groups are
    /// flattened back to plain rows — a lone sub-issue doesn't earn a header.
    var visibleEntries: [LinearInboxEntry] {
      var entries: [LinearInboxEntry] = []
      var groupIndexByParent: [String: Int] = [:]
      for ticket in visibleTickets {
        guard let parent = ticket.parentIdentifier, !parent.isEmpty else {
          entries.append(.ticket(ticket))
          continue
        }
        if let index = groupIndexByParent[parent], case .group(var group) = entries[index] {
          group.children.append(ticket)
          entries[index] = .group(group)
        } else {
          groupIndexByParent[parent] = entries.count
          entries.append(
            .group(
              LinearTicketGroup(
                parentIdentifier: parent,
                parentTitle: ticket.parentTitle,
                children: [ticket]
              )
            )
          )
        }
      }
      return entries.map { entry in
        if case .group(let group) = entry, group.children.count == 1 {
          return .ticket(group.children[0])
        }
        return entry
      }
    }

    /// The live board session linked to this ticket, or nil if none. Prefers
    /// the explicit link stamped when the session was started from the inbox,
    /// then falls back to discovering any live session whose primary ticket is
    /// this one — so sessions started outside the inbox link up too.
    func liveLinkedSessionID(for ticket: LinearTicket) -> UUID? {
      if let sessionID = ticket.startedSessionID, sessions.contains(where: { $0.id == sessionID }) {
        return sessionID
      }
      return sessions.first(where: { $0.primaryTicketID == ticket.identifier })?.id
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
    /// Switch the visible source (recent vs pasted) and refresh it.
    case sourceChanged(LinearTicketSource)
    /// Import the pasted text. `replace: true` rebuilds the pasted list
    /// (keeping metadata for surviving ids); `false` appends new ids only.
    case importTapped(replace: Bool)
    /// Re-pull the most recently created tickets straight from Linear.
    case fetchRecentTapped
    case refreshAllTapped
    case toggleExpanded(ticketID: String)
    /// Expand or collapse a parent group to show/hide its bundled sub-issues.
    case toggleGroupExpanded(parentID: String)
    case assignToMeTapped(ticketID: String)
    case startSessionTapped(ticketID: String)
    /// Jump to the session already spawned from this ticket.
    case openSessionTapped(ticketID: String)
    case removeTicketTapped(ticketID: String)
    /// Ignore (or un-ignore) a single ticket — kept in the inbox but off the
    /// worklist until the "Ignored" filter reveals it.
    case toggleIgnoreTapped(ticketID: String)
    case toggleShowDone
    case toggleShowIgnored
    case toggleAssignedToMe
    case toggleHideInProgress
    case toggleHideLinked
    case clearError
    case closeTapped

    case _issuesFetched([LinearIssue])
    case _recentIssuesFetched([LinearIssue])
    case _fetchFailed(message: String)
    case _assignCompleted(ticketID: String, LinearIssue?)
    case _assignFailed(ticketID: String, message: String)
    /// The start-session auto-sync (assign-to-me + move to In Progress)
    /// landed; fold the authoritative record back in.
    case _inProgressSyncCompleted(ticketID: String, LinearIssue?)
    /// The auto-sync failed — restore the optimistically flipped fields.
    case _inProgressSyncFailed(
      ticketID: String,
      message: String,
      previousAssignedToMe: Bool,
      previousStateName: String?,
      previousStateType: String?
    )

    case newTerminal(PresentationAction<NewTerminalFeature.Action>)
    case delegate(Delegate)

    @CasePathable
    enum Delegate: Equatable {
      /// Bubble the embedded New Terminal sheet's delegate up to
      /// BoardFeature, which owns spawning, bookmarks and drafts.
      case newTerminalDelegate(NewTerminalFeature.Action.Delegate)
      /// Dismiss the inbox and focus this session on the board.
      case openSession(sessionID: UUID)
    }
  }

  /// How many recently created tickets the recent feed pulls. Linear caps a
  /// single page at 250, so we pull the full page: a busy team's latest 100 are
  /// mostly done / in-progress / linked, and after the quick filters the
  /// actionable worklist shrinks to a handful — a deeper feed surfaces more of
  /// the tickets that haven't been picked up yet without paying for paging.
  static let recentFetchLimit = 250

  /// Done tickets linger this long (measured from Linear's own
  /// completed/canceled timestamp) before they auto-drop from the inbox.
  static let doneRetention: TimeInterval = 3 * 24 * 60 * 60

  @Dependency(LinearClient.self) var linearClient
  @Dependency(\.date) var date
  @Dependency(\.dismiss) var dismiss

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding(\.selectedRepositoryID):
        // Switching repos swaps the visible bucket — refresh that repo's
        // current source so the worklist isn't stale.
        state.expandedTicketIDs = []
        state.expandedGroupIDs = []
        pruneExpiredDoneTickets(&state)
        return refreshCurrentSource(&state)

      case .binding:
        return .none

      case .task:
        migrateLegacyInboxIfNeeded(&state)
        pruneExpiredDoneTickets(&state)
        // Recent mode auto-loads on open (no button); pasted mode refreshes
        // the curated set's metadata.
        return refreshCurrentSource(&state)

      case let .sourceChanged(newSource):
        guard newSource != state.source else { return .none }
        state.$inboxSourceRaw.withLock { $0 = newSource.rawValue }
        state.expandedTicketIDs = []
        state.expandedGroupIDs = []
        state.errorMessage = nil
        return refreshCurrentSource(&state)

      case let .importTapped(replace):
        let ids = linearTicketIDs(in: state.pasteText)
        guard !ids.isEmpty else {
          state.errorMessage = "No Linear ticket links found in the pasted text."
          return .none
        }
        // Pasting curates the pasted set, so jump there to show the result.
        state.$inboxSourceRaw.withLock { $0 = LinearTicketSource.pasted.rawValue }
        let now = date.now
        mutateSelectedTickets(&state) { bucket in
          var pasted = bucket.filter { $0.source == .pasted }
          if replace {
            // Preserve inbox-local metadata for ids that survive the
            // replace so "started" markers don't reset.
            let existing = Dictionary(pasted.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
            pasted = ids.map { existing[$0] ?? LinearTicket(identifier: $0, source: .pasted, addedAt: now) }
          } else {
            for id in ids where !pasted.contains(where: { $0.identifier == id }) {
              pasted.append(LinearTicket(identifier: id, source: .pasted, addedAt: now))
            }
          }
          bucket = bucket.filter { $0.source != .pasted } + pasted
        }
        state.pasteText = ""
        state.errorMessage = nil
        state.fetchingTicketIDs = Set(ids)
        return fetchIssues(ids: ids)

      case .fetchRecentTapped:
        return startRecentFetch(&state)

      case .refreshAllTapped:
        state.errorMessage = nil
        return refreshCurrentSource(&state)

      case let .toggleExpanded(ticketID):
        if state.expandedTicketIDs.contains(ticketID) {
          state.expandedTicketIDs.remove(ticketID)
        } else {
          state.expandedTicketIDs.insert(ticketID)
        }
        return .none

      case let .toggleGroupExpanded(parentID):
        if state.expandedGroupIDs.contains(parentID) {
          state.expandedGroupIDs.remove(parentID)
        } else {
          state.expandedGroupIDs.insert(parentID)
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
        // Setting the prompt programmatically bypasses the `binding(\.prompt)`
        // path that normally resolves the ticket title and arms the worktree.
        // The inbox already knows the title, so seed the cache and run the
        // same auto-fill the New Terminal screen uses.
        if let title = ticket.title, !title.isEmpty {
          newTerminal.linearTitleCache[ticket.identifier.uppercased()] = title
          _ = NewTerminalFeature.maybeAutoFillWorkspaceQueryFromLinear(state: &newTerminal)
        }
        state.newTerminal = newTerminal
        state.selectedTab = .newTerminal
        return .none

      case let .openSessionTapped(ticketID):
        guard let ticket = state.tickets.first(where: { $0.identifier == ticketID }),
          let sessionID = state.liveLinkedSessionID(for: ticket)
        else { return .none }
        return .send(.delegate(.openSession(sessionID: sessionID)))

      case let .removeTicketTapped(ticketID):
        mutateSelectedTickets(&state) { $0.removeAll { $0.identifier == ticketID } }
        state.expandedTicketIDs.remove(ticketID)
        return .none

      case let .toggleIgnoreTapped(ticketID):
        mutateSelectedTickets(&state) { tickets in
          guard let index = tickets.firstIndex(where: { $0.identifier == ticketID }) else { return }
          tickets[index].isHidden.toggle()
        }
        return .none

      case .toggleShowDone:
        state.showDone.toggle()
        return .none

      case .toggleShowIgnored:
        state.showIgnored.toggle()
        return .none

      case .toggleAssignedToMe:
        state.assignedToMeOnly.toggle()
        return .none

      case .toggleHideInProgress:
        state.hideInProgress.toggle()
        return .none

      case .toggleHideLinked:
        state.hideLinked.toggle()
        return .none

      case .clearError:
        state.errorMessage = nil
        return .none

      case .closeTapped:
        return .run { _ in await dismiss() }

      case let ._issuesFetched(issues):
        let now = date.now
        let byID = Dictionary(issues.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        mutateSelectedTickets(&state) { tickets in
          for index in tickets.indices {
            if let issue = byID[tickets[index].identifier] {
              tickets[index].apply(issue, fetchedAt: now)
            }
          }
        }
        // One batch fetch resolves the whole in-flight set.
        state.fetchingTicketIDs = []
        // Fresh `doneAt` stamps may have pushed tickets past retention.
        pruneExpiredDoneTickets(&state)
        return .none

      case let ._recentIssuesFetched(issues):
        state.isFetchingRecent = false
        guard !issues.isEmpty else {
          state.errorMessage = "No recently created tickets found in Linear."
          return .none
        }
        // The recent set is a live mirror of Linear's latest-created feed, so
        // rebuild it wholesale: carry forward inbox-local metadata (started,
        // ignored) for surviving ids, drop ids that fell out of the feed, and
        // leave the pasted set untouched. Ids already curated under Pasted are
        // skipped so the bucket keeps unique identifiers.
        let now = date.now
        mutateSelectedTickets(&state) { bucket in
          let survivingRecent = Dictionary(
            bucket.filter { $0.source == .recent }.map { ($0.identifier, $0) },
            uniquingKeysWith: { first, _ in first }
          )
          let pastedIDs = Set(bucket.filter { $0.source == .pasted }.map(\.identifier))
          var rebuilt = bucket.filter { $0.source == .pasted }
          for issue in issues where !pastedIDs.contains(issue.identifier) {
            var ticket = survivingRecent[issue.identifier]
              ?? LinearTicket(identifier: issue.identifier, source: .recent, addedAt: now)
            ticket.apply(issue, fetchedAt: now)
            rebuilt.append(ticket)
          }
          bucket = rebuilt
        }
        pruneExpiredDoneTickets(&state)
        return .none

      case let ._fetchFailed(message):
        state.fetchingTicketIDs = []
        state.isFetchingRecent = false
        state.errorMessage = message
        return .none

      case let ._assignCompleted(ticketID, issue):
        state.assigningTicketIDs.remove(ticketID)
        let now = date.now
        mutateSelectedTickets(&state) { tickets in
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

      case let ._inProgressSyncCompleted(ticketID, issue):
        guard let issue else { return .none }
        let now = date.now
        mutateSelectedTickets(&state) { tickets in
          if let index = tickets.firstIndex(where: { $0.identifier == ticketID }) {
            // `apply` refreshes assignee/state from Linear but leaves the
            // local `startedAt`/`startedSessionID` stamps intact.
            tickets[index].apply(issue, fetchedAt: now)
          }
        }
        return .none

      case let ._inProgressSyncFailed(ticketID, message, previousAssignedToMe, previousStateName, previousStateType):
        // Roll back just the two optimistically flipped fields. The local
        // "started" stamp stays — the session really did launch.
        mutateSelectedTickets(&state) { tickets in
          guard let index = tickets.firstIndex(where: { $0.identifier == ticketID }) else { return }
          tickets[index].assignedToMe = previousAssignedToMe
          tickets[index].stateName = previousStateName
          tickets[index].stateType = previousStateType
        }
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
          // Stamp the originating ticket as started (with the session id,
          // so the row can jump back to it later), then hand the spawn
          // to BoardFeature (it closes the tab and owns the lifecycle).
          var syncEffect: Effect<Action> = .none
          if let ticketID = state.pendingSessionTicketID {
            let now = date.now
            let sessionID: UUID? =
              switch inner {
              case .created(let session): session.id
              case .spawnRequested(let request, _, _): request.sessionID
              default: nil
              }
            mutateSelectedTickets(&state) { tickets in
              if let index = tickets.firstIndex(where: { $0.identifier == ticketID }) {
                tickets[index].startedAt = now
                tickets[index].startedSessionID = sessionID
              }
            }
            // Collapse the row so landing back on the list visibly reacts
            // to the submit: the summary line now carries the started
            // checkmark (and "Open session" once the spawn completes).
            state.expandedTicketIDs.remove(ticketID)
            // Picking up a ticket means it's yours and in progress — reflect
            // that in Linear, optimistically so the row reacts immediately.
            syncEffect = autoProgressEffect(&state, ticketID: ticketID)
          }
          state.pendingSessionTicketID = nil
          state.selectedTab = .inbox
          return .merge(syncEffect, .send(.delegate(.newTerminalDelegate(inner))))
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

  /// Drops tickets that Linear finished more than `doneRetention` ago.
  /// Tickets done with an unknown timestamp are kept — the next fetch
  /// stamps `doneAt` and they age out from there.
  private func pruneExpiredDoneTickets(_ state: inout State) {
    let cutoff = date.now.addingTimeInterval(-Self.doneRetention)
    mutateSelectedTickets(&state) { tickets in
      tickets.removeAll { ticket in
        guard ticket.isDone, let doneAt = ticket.doneAt else { return false }
        return doneAt < cutoff
      }
    }
  }

  /// Mutate the selected repository's ticket bucket in place. No-ops when no
  /// repo is selected (an empty inbox), so callers stay branch-free.
  private func mutateSelectedTickets(_ state: inout State, _ body: (inout [LinearTicket]) -> Void) {
    guard let repositoryID = state.selectedRepositoryID else { return }
    state.$inbox.withLock { inbox in
      var bucket = inbox[repositoryID] ?? []
      body(&bucket)
      inbox[repositoryID] = bucket
    }
  }

  /// This repo's configured Linear team keys (e.g. `["CEN"]`), normalized.
  private func teamKeys(for repository: Repository) -> [String] {
    @Shared(.repositorySettings(repository.rootURL)) var settings
    return parseLinearTeamKeys(settings.linearTeamKeys).sorted()
  }

  /// One-time upgrade: tickets recovered from the pre-repo-scoping flat file
  /// land under `LinearInboxKey.legacyBucketKey`. Redistribute them into the
  /// right repo bucket by matching each ticket's prefix to a repo's team keys,
  /// falling back to the selected repo so nothing is lost, then clear the
  /// reserved bucket.
  private func migrateLegacyInboxIfNeeded(_ state: inout State) {
    guard
      let legacy = state.inbox[LinearInboxKey.legacyBucketKey],
      !legacy.isEmpty
    else { return }

    var prefixToRepo: [String: Repository.ID] = [:]
    for repository in state.availableRepositories {
      for key in teamKeys(for: repository) where prefixToRepo[key] == nil {
        prefixToRepo[key] = repository.id
      }
    }
    let fallback = state.selectedRepositoryID ?? state.availableRepositories.first?.id

    state.$inbox.withLock { inbox in
      for ticket in legacy {
        let prefix = ticket.identifier.split(separator: "-").first.map { $0.uppercased() } ?? ""
        guard let target = prefixToRepo[prefix] ?? fallback else { continue }
        if !(inbox[target]?.contains(where: { $0.identifier == ticket.identifier }) ?? false) {
          inbox[target, default: []].append(ticket)
        }
      }
      inbox[LinearInboxKey.legacyBucketKey] = nil
    }
  }

  /// On session start, optimistically flip the row to "mine, in progress" and
  /// push the same to Linear (assign-to-me + move to the team's In Progress
  /// state). Skips whichever half is already true, and reverts both fields if
  /// the mutation fails. The local "started" stamp is independent and never
  /// reverts. No-ops without a cached `linearID` (mutations need the UUID).
  private func autoProgressEffect(_ state: inout State, ticketID: String) -> Effect<Action> {
    guard
      let ticket = state.tickets.first(where: { $0.identifier == ticketID }),
      let linearID = ticket.linearID
    else { return .none }

    let shouldAssign = !ticket.assignedToMe
    // Don't drag a done/canceled ticket back to In Progress, and don't bump an
    // already-started ticket (e.g. In Review) backwards.
    let shouldStart = !ticket.isDone && !ticket.isInProgress
    guard shouldAssign || shouldStart else { return .none }

    let previousAssignedToMe = ticket.assignedToMe
    let previousStateName = ticket.stateName
    let previousStateType = ticket.stateType

    mutateSelectedTickets(&state) { tickets in
      guard let index = tickets.firstIndex(where: { $0.identifier == ticketID }) else { return }
      if shouldAssign { tickets[index].assignedToMe = true }
      if shouldStart {
        tickets[index].stateType = "started"
        tickets[index].stateName = "In Progress"
      }
    }

    return .run { send in
      do {
        var latest: LinearIssue?
        if shouldAssign { latest = try await linearClient.assignToMe(linearID) }
        // Run after the assign so the returned record carries both updates.
        if shouldStart { latest = try await linearClient.startProgress(linearID) ?? latest }
        await send(._inProgressSyncCompleted(ticketID: ticketID, latest))
      } catch {
        await send(._inProgressSyncFailed(
          ticketID: ticketID,
          message: error.localizedDescription,
          previousAssignedToMe: previousAssignedToMe,
          previousStateName: previousStateName,
          previousStateType: previousStateType
        ))
      }
    }
  }

  /// Refresh whichever source is on screen: recent re-pulls Linear's latest
  /// feed; pasted re-fetches metadata for the curated ids.
  private func refreshCurrentSource(_ state: inout State) -> Effect<Action> {
    switch state.source {
    case .recent:
      return startRecentFetch(&state)
    case .pasted:
      let ids = state.tickets.map(\.identifier)
      guard !ids.isEmpty else { return .none }
      state.fetchingTicketIDs = Set(ids)
      return fetchIssues(ids: ids)
    }
  }

  /// Kick off the recent-feed pull, scoped to the selected repo's team keys.
  /// An empty scope makes the client throw `.missingTeamScope`, prompting the
  /// user to set a key under Settings → <repository> → Linear.
  private func startRecentFetch(_ state: inout State) -> Effect<Action> {
    state.isFetchingRecent = true
    state.errorMessage = nil
    let scopeKeys = state.selectedRepository.map { teamKeys(for: $0) } ?? []
    return .run { send in
      do {
        let issues = try await linearClient.fetchRecentIssues(Self.recentFetchLimit, scopeKeys)
        await send(._recentIssuesFetched(issues))
      } catch {
        await send(._fetchFailed(message: error.localizedDescription))
      }
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

/// One row in the inbox list: a standalone ticket, or a parent group that
/// bundles its visible sub-issues behind a single expandable header.
nonisolated enum LinearInboxEntry: Equatable, Identifiable, Sendable {
  case ticket(LinearTicket)
  case group(LinearTicketGroup)

  var id: String {
    switch self {
    case .ticket(let ticket): "ticket:\(ticket.identifier)"
    case .group(let group): "group:\(group.parentIdentifier)"
    }
  }
}

/// A parent issue and the visible sub-issues bundled under it. The parent
/// metadata is whatever a child carried (`parentTitle`); the inbox never
/// fetches the parent separately for the MVP.
nonisolated struct LinearTicketGroup: Equatable, Identifiable, Sendable {
  let parentIdentifier: String
  let parentTitle: String?
  var children: [LinearTicket]
  var id: String { parentIdentifier }
}

extension AgentSession {
  /// The Linear ticket this session is primarily about: its first ticket
  /// reference, falling back to the first ticket id in its launch prompt.
  /// Used by the inbox to link a ticket to a session that wasn't started
  /// from the inbox itself.
  nonisolated var primaryTicketID: String? {
    for reference in references {
      if case let .ticket(id) = reference { return id }
    }
    return firstLinearTicketID(in: initialPrompt)
  }
}
