import Foundation

/// Where a ticket in the inbox came from. The inbox shows one source at a
/// time (the user toggles between them); ``LinearInboxFeature`` persists the
/// selected source so reopening restores the same view. Doubles as the
/// per-ticket provenance tag so both sets can live in one persisted bucket.
nonisolated enum LinearTicketSource: String, Codable, Sendable, CaseIterable, Equatable {
  /// Pulled from Linear's most-recently-created feed (auto-fetched on open).
  case recent
  /// Hand-pasted (or typed) ticket links the user curated themselves.
  case pasted
}

/// A Linear ticket the user dropped into the Inbox to work through. Sits in
/// `@Shared(.linearInbox)` so the list survives relaunch — the user can
/// close the dialog and come back to pick the next one.
///
/// Identity is the human ticket key (`CEN-7404`); pasting the same id twice
/// is a no-op upsert rather than a duplicate. Display fields are a cache of
/// the last successful API fetch, so a row still renders something useful
/// while offline or before a refresh completes. `linearID` is the internal
/// UUID needed by the assign mutation, cached after the first fetch.
///
/// Persistence: forward-compatible Codable per `docs/agent-guides/persistence.md`.
/// Every field except `identifier` decodes via `decodeIfPresent ?? default`.
nonisolated struct LinearTicket: Identifiable, Equatable, Hashable, Codable, Sendable {
  /// Human ticket key, e.g. `CEN-7404`. Stable identity for the row.
  let identifier: String
  var id: String { identifier }

  /// Linear's internal UUID, cached after the first successful fetch.
  /// Required by `LinearClient.assignToMe`; nil until we've fetched once.
  var linearID: String?
  var title: String?
  var summary: String?
  var stateName: String?
  /// Linear workflow state category (`backlog`/`unstarted`/`started`/
  /// `completed`/`canceled`); `isDone` keys off this.
  var stateType: String?
  var assigneeName: String?
  var assignedToMe: Bool
  var url: String?
  /// When Linear marked the ticket completed/canceled (its own
  /// `completedAt`/`canceledAt`, not when we noticed). Tickets done for
  /// more than `LinearInboxFeature.doneRetention` are auto-dropped.
  var doneAt: Date?
  /// Which inbox view this ticket belongs to. Recent-fetched tickets are
  /// replaced wholesale on every refresh; pasted tickets are durable.
  var source: LinearTicketSource

  /// User chose to ignore this row — kept in the inbox but off the worklist
  /// until the "Ignored" quick filter reveals it. (Field name predates the
  /// "ignore" framing; left as-is to preserve persisted data.)
  var isHidden: Bool

  /// When the cached display fields were last refreshed from the API.
  var fetchedAt: Date?
  /// When the user added this ticket to the inbox.
  let addedAt: Date
  /// Non-nil once the user kicked off a coding session on this ticket —
  /// drives the "in progress" check mark so you can see what's been picked.
  var startedAt: Date?
  /// Id of the `AgentSession` spawned from this ticket, recorded alongside
  /// `startedAt`. Lets the row jump straight to the session instead of
  /// starting a duplicate. The session may have been deleted since —
  /// always check it still exists before navigating.
  var startedSessionID: UUID?

  init(
    identifier: String,
    linearID: String? = nil,
    title: String? = nil,
    summary: String? = nil,
    stateName: String? = nil,
    stateType: String? = nil,
    assigneeName: String? = nil,
    assignedToMe: Bool = false,
    url: String? = nil,
    source: LinearTicketSource = .pasted,
    doneAt: Date? = nil,
    isHidden: Bool = false,
    fetchedAt: Date? = nil,
    addedAt: Date = Date(),
    startedAt: Date? = nil,
    startedSessionID: UUID? = nil
  ) {
    self.identifier = identifier
    self.linearID = linearID
    self.title = title
    self.summary = summary
    self.stateName = stateName
    self.stateType = stateType
    self.assigneeName = assigneeName
    self.assignedToMe = assignedToMe
    self.url = url
    self.source = source
    self.doneAt = doneAt
    self.isHidden = isHidden
    self.fetchedAt = fetchedAt
    self.addedAt = addedAt
    self.startedAt = startedAt
    self.startedSessionID = startedSessionID
  }

  // MARK: - Codable (forward-compatible)

  enum CodingKeys: String, CodingKey {
    case identifier, linearID, title, summary, stateName, stateType, assigneeName
    case assignedToMe, url, source, doneAt, isHidden, fetchedAt, addedAt, startedAt, startedSessionID
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    identifier = try c.decode(String.self, forKey: .identifier)
    linearID = try c.decodeIfPresent(String.self, forKey: .linearID)
    title = try c.decodeIfPresent(String.self, forKey: .title)
    summary = try c.decodeIfPresent(String.self, forKey: .summary)
    stateName = try c.decodeIfPresent(String.self, forKey: .stateName)
    stateType = try c.decodeIfPresent(String.self, forKey: .stateType)
    assigneeName = try c.decodeIfPresent(String.self, forKey: .assigneeName)
    assignedToMe = try c.decodeIfPresent(Bool.self, forKey: .assignedToMe) ?? false
    url = try c.decodeIfPresent(String.self, forKey: .url)
    // Pre-source builds persisted only hand-curated tickets — default to
    // `.pasted` so they keep showing under the Pasted view after upgrade.
    source = try c.decodeIfPresent(LinearTicketSource.self, forKey: .source) ?? .pasted
    doneAt = try c.decodeIfPresent(Date.self, forKey: .doneAt)
    isHidden = try c.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
    fetchedAt = try c.decodeIfPresent(Date.self, forKey: .fetchedAt)
    addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
    startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
    startedSessionID = try c.decodeIfPresent(UUID.self, forKey: .startedSessionID)
  }

  // MARK: - Updates

  /// Folds a freshly fetched API record into the cached display fields,
  /// preserving inbox-local state (`addedAt`, `startedAt`).
  mutating func apply(_ issue: LinearIssue, fetchedAt: Date) {
    linearID = issue.id
    title = issue.title
    summary = issue.description
    stateName = issue.stateName
    stateType = issue.stateType
    assigneeName = issue.assigneeName
    assignedToMe = issue.assignedToMe
    url = issue.url
    doneAt = issue.completedAt ?? issue.canceledAt
    self.fetchedAt = fetchedAt
  }

  // MARK: - Display

  /// True once Linear reports the ticket in a completed or canceled state.
  /// Unknown (not yet fetched) tickets are never done. Drives the inbox's
  /// "done" count and show/hide filter.
  var isDone: Bool {
    stateType == "completed" || stateType == "canceled"
  }

  /// Prompt seed for a coding session, e.g. `Fix CEN-7404: <title>`.
  var sessionPrompt: String {
    if let title, !title.isEmpty {
      return "Fix \(identifier): \(title)"
    }
    return "Fix \(identifier)"
  }
}
