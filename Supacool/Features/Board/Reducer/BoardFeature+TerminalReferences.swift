import ComposableArchitecture
import Foundation

/// Feeds `@Shared(.terminalReferenceCatalog)`: the ticket and PR facts the
/// terminal layer uses to tint ticket ids / PR refs by state and to fill the
/// ⌘-hover card. PR facts are already on the board (reference snapshots, PR
/// Pulse); Linear ticket states are fetched here for every ticket a session
/// references.
extension BoardFeature {
  /// How long a fetched (or failed) ticket stays fresh before the next tick
  /// asks Linear again.
  nonisolated static let terminalTicketRefreshAge: TimeInterval = 5 * 60
  /// Max ids per Linear request. Ids past the cap go out on the next tick.
  nonisolated static let terminalTicketBatchLimit = 50

  /// Everything the catalog is built from. Compared on every action, so it
  /// stays cheap: unchanged arrays and dictionaries compare by identity.
  nonisolated struct TerminalReferenceInputs: Equatable {
    var sessions: [AgentSession]
    var prReferenceSnapshots: [String: PullRequestSnapshot]
    var prPulseSnapshots: [String: RepoPullRequestSnapshot]
    var terminalTicketIssues: [String: LinearIssue]
  }

  func refreshTerminalTickets(state: inout State) -> Effect<Action> {
    guard !state.terminalTicketFetchInFlight else { return .none }
    let ids = Self.terminalTicketCandidates(
      sessions: state.sessions,
      attemptedAt: state.terminalTicketAttemptedAt,
      now: date.now
    )
    guard !ids.isEmpty else { return .none }
    state.terminalTicketFetchInFlight = true
    return .run { [linearClient] send in
      // No API key, offline, rate-limited: all the same here — the ids
      // stay uncolored and get retried after `terminalTicketRefreshAge`.
      let issues = (try? await linearClient.fetchIssues(ids)) ?? []
      await send(._terminalTicketsLoaded(attempted: ids, issues: issues))
    }
  }

  func reduceTerminalTicketsLoaded(
    state: inout State,
    attempted: [String],
    issues: [LinearIssue]
  ) -> Effect<Action> {
    state.terminalTicketFetchInFlight = false
    let now = date.now
    for id in attempted {
      state.terminalTicketAttemptedAt[id] = now
    }
    for issue in issues {
      state.terminalTicketIssues[issue.identifier] = issue
    }
    return .none
  }

  /// Publish the catalog. Skips the write when nothing visible changed, so
  /// the terminal layer's observer only fires on real news.
  func publishTerminalReferenceCatalog(state: State) {
    let catalog = TerminalReferenceCatalog.build(
      sessions: state.sessions,
      referenceSnapshots: state.prReferenceSnapshots,
      pulseSnapshots: state.prPulseSnapshots,
      linearIssues: state.terminalTicketIssues
    )
    @Shared(.terminalReferenceCatalog) var shared
    guard shared != catalog else { return }
    $shared.withLock { $0 = catalog }
  }

  /// Ticket ids referenced by any session that were never fetched or were
  /// fetched longer than `terminalTicketRefreshAge` ago, never-fetched first.
  nonisolated static func terminalTicketCandidates(
    sessions: [AgentSession],
    attemptedAt: [String: Date],
    now: Date
  ) -> [String] {
    var seen = Set<String>()
    var fresh: [String] = []
    var stale: [(id: String, at: Date)] = []
    for session in sessions {
      for reference in session.references {
        guard case .ticket(let id) = reference, seen.insert(id).inserted else { continue }
        if let at = attemptedAt[id] {
          if now.timeIntervalSince(at) >= terminalTicketRefreshAge { stale.append((id, at)) }
        } else {
          fresh.append(id)
        }
      }
    }
    let ordered = fresh + stale.sorted { $0.at < $1.at }.map(\.id)
    return Array(ordered.prefix(terminalTicketBatchLimit))
  }
}

extension BoardFeature.State {
  var terminalReferenceInputs: BoardFeature.TerminalReferenceInputs {
    BoardFeature.TerminalReferenceInputs(
      sessions: sessions,
      prReferenceSnapshots: prReferenceSnapshots,
      prPulseSnapshots: prPulseSnapshots,
      terminalTicketIssues: terminalTicketIssues
    )
  }
}
