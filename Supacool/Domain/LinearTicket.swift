import Foundation

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
    self.fetchedAt = fetchedAt
    self.addedAt = addedAt
    self.startedAt = startedAt
    self.startedSessionID = startedSessionID
  }

  // MARK: - Codable (forward-compatible)

  enum CodingKeys: String, CodingKey {
    case identifier, linearID, title, summary, stateName, stateType, assigneeName
    case assignedToMe, url, fetchedAt, addedAt, startedAt, startedSessionID
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
