import ComposableArchitecture
import Foundation

private nonisolated let linearClientLogger = SupaLogger("Supacool.Linear")

/// A single Linear issue, flattened to just the fields the board needs.
///
/// `id` is Linear's internal UUID (required by the `issueUpdate` mutation);
/// `identifier` is the human ticket key shown in the UI (e.g. `CEN-7404`).
nonisolated struct LinearIssue: Equatable, Sendable, Identifiable {
  /// Linear's internal UUID. Use this for mutations (`issueUpdate`).
  var id: String
  /// Human ticket key, e.g. `CEN-7404`.
  var identifier: String
  var title: String
  /// Markdown body. Nil when unknown (not yet fetched).
  var description: String?
  /// Workflow state name, e.g. `In Progress`.
  var stateName: String?
  /// Workflow state category, one of Linear's state types: `backlog`,
  /// `unstarted`, `started`, `completed`, `canceled`. Drives "done".
  var stateType: String? = nil
  /// Assignee display name, or nil when unassigned.
  var assigneeName: String?
  /// True when the current API-key holder is the assignee.
  var assignedToMe: Bool
  /// Display name of whoever filed the issue, or nil when unknown.
  var creatorName: String? = nil
  /// Canonical web URL for the issue.
  var url: String?
  /// When the issue was created in Linear. Drives the inbox's per-row age.
  var createdAt: Date? = nil
  /// When Linear marked the issue completed / canceled. Drives the
  /// inbox's auto-drop of stale done tickets.
  var completedAt: Date? = nil
  var canceledAt: Date? = nil
  /// Parent issue's human key (e.g. `CEN-7735`) when this issue is a
  /// sub-issue, else nil. Lets the inbox bundle siblings under one row.
  var parentIdentifier: String? = nil
  /// Parent issue's title, cached for the group header so the inbox needn't
  /// fetch the parent separately.
  var parentTitle: String? = nil
}

/// Minimal Linear API client. Originally just fetched a single issue title
/// for the New Terminal sheet (typing `CEN-6690` into the prompt seeds the
/// branch name and card `displayName`). Extended for the Linear Inbox to
/// batch-fetch issues and assign them to the current user.
///
/// API key lives in UserDefaults under `supacool.linear.apiKey`. Either
/// a Personal API Key (`lin_api_…`, sent raw in the `Authorization`
/// header per Linear's docs) or an OAuth bearer token works.
/// A ticket's naming payload: its human title plus Linear's own suggested
/// git branch name (e.g. `johannes/cen-6690-streamline-the-foobar`, owner
/// segment intact — the caller strips it). `branchName` is nil when Linear
/// didn't return one. `ExpressibleByStringLiteral` so tests can keep
/// stubbing a bare title string.
nonisolated struct LinearIssueNaming: Equatable, Sendable, ExpressibleByStringLiteral {
  var title: String
  var branchName: String?

  init(title: String, branchName: String? = nil) {
    self.title = title
    self.branchName = branchName
  }

  init(stringLiteral value: String) {
    self.init(title: value)
  }
}

struct LinearClient: Sendable {
  /// Returns the title and Linear-suggested git branch name for the given
  /// identifier. Returns `nil` when the API resolves but the issue doesn't
  /// exist (a genuine "not found"). Throws on network / API errors, and
  /// `.missingAPIKey` when no key is configured — the New Terminal sheet
  /// treats a throw as a *transient* miss it can retry (and surface),
  /// rather than a sticky negative, so adding a key later doesn't require
  /// reopening the sheet.
  var fetchIssueNaming: @Sendable (_ id: String) async throws -> LinearIssueNaming?

  /// Batch-fetches full issue records for the given identifiers (e.g.
  /// `["CEN-7404", "CEN-7405"]`). Identifiers that don't resolve are
  /// silently dropped, so the result may be shorter than the input and
  /// in a different order — match back by `identifier`. Throws
  /// `.missingAPIKey` when no key is configured so the inbox can prompt.
  var fetchIssues: @Sendable (_ ids: [String]) async throws -> [LinearIssue]

  /// Assigns the issue (by Linear UUID) to the current API-key holder and
  /// returns the updated record. Throws `.missingAPIKey` when unconfigured.
  var assignToMe: @Sendable (_ issueUUID: String) async throws -> LinearIssue?

  /// Moves the issue (by Linear UUID) into its team's first `started`
  /// workflow state — canonically "In Progress" — and returns the updated
  /// record. No-ops (returns the issue unchanged) when it's already in a
  /// `started` state so an "In Review" ticket isn't dragged backwards.
  /// Throws `.missingAPIKey` when unconfigured.
  var startProgress: @Sendable (_ issueUUID: String) async throws -> LinearIssue?

  /// Fetches the most recently created issues, newest first, scoped to the
  /// given Linear team keys (e.g. `["CEN"]`). The keys are sourced per-repo
  /// (`RepositorySettings.linearTeamKeys`) by the caller — the inbox unions
  /// them across repos — so a multi-team workspace can't flood the inbox.
  /// Throws `.missingTeamScope` when `teamKeys` is empty rather than falling
  /// back to an org-wide query, and `.missingAPIKey` when no key is
  /// configured so the inbox can prompt.
  var fetchRecentIssues: @Sendable (_ limit: Int, _ teamKeys: [String]) async throws -> [LinearIssue]
}

extension LinearClient {
  /// One of a team's workflow states, flattened for `startProgress`'s
  /// target-selection logic.
  nonisolated struct WorkflowState: Equatable, Sendable {
    var id: String
    var name: String
    var type: String
    var position: Double
  }

  /// Picks the workflow state to move an issue into when "starting" it.
  ///
  /// A team can define several `started`-type states — Linear's defaults are
  /// "In Progress" and "In Review", and teams routinely add "Blocked",
  /// "Paused", etc. `position` alone is unreliable: "Blocked" can sort ahead
  /// of "In Progress" (it does on CEN), so the lowest-position started state
  /// isn't necessarily the one you want. So: drop holding states (blocked /
  /// review / paused / on-hold / waiting) from consideration, prefer a state
  /// whose name reads like active work, then fall back to lowest position.
  nonisolated static func canonicalStartedStateID(from states: [WorkflowState]) -> String? {
    let started = states.filter { $0.type == "started" }
    guard !started.isEmpty else { return nil }

    let holdingMarkers = ["block", "review", "pause", "hold", "wait"]
    let active = started.filter { state in
      let name = state.name.lowercased()
      return !holdingMarkers.contains { name.contains($0) }
    }
    // If every started state looks like a holding state, fall back to all of
    // them rather than returning nothing.
    let pool = active.isEmpty ? started : active

    let preferred = pool.first {
      let name = $0.name.lowercased()
      return name.contains("progress") || name.contains("doing")
    }
    return (preferred ?? pool.min { $0.position < $1.position })?.id
  }
}

nonisolated enum LinearClientError: LocalizedError {
  case invalidResponse
  case missingAPIKey
  case missingTeamScope
  case unauthorized
  case notFound(String)
  case requestFailed(status: Int, body: String)

  var errorDescription: String? {
    switch self {
    case .invalidResponse:
      return "Unexpected response from the Linear API."
    case .missingAPIKey:
      return "No Linear API key configured. Add one in Settings → Linear."
    case .missingTeamScope:
      return "No Linear team key configured for any repository. Add your team key (e.g. CEN) under "
        + "Settings → <repository> → Linear so the import only pulls that repo's tickets."
    case .unauthorized:
      return "Linear API key is invalid or missing required scopes."
    case .notFound(let id):
      return "Linear issue \(id) not found."
    case .requestFailed(let status, let body):
      let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
      return "Linear API request failed (\(status))\(trimmed.isEmpty ? "" : ": \(trimmed)")."
    }
  }
}

extension LinearClient: DependencyKey {
  static let liveValue = Self(
    fetchIssueNaming: { id in
      let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return nil }
      // No key throws (not nil): the sheet then shows "add a key" and
      // retries on the next paste, instead of silently negative-caching
      // the id for the sheet's whole life.
      guard let key = LinearLive.currentAPIKey() else {
        throw LinearClientError.missingAPIKey
      }
      return try await LinearLive.fetchIssueNaming(id: trimmed, apiKey: key)
    },
    fetchIssues: { ids in
      let trimmed = ids.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
      guard !trimmed.isEmpty else { return [] }
      guard let key = LinearLive.currentAPIKey() else { throw LinearClientError.missingAPIKey }
      return try await LinearLive.fetchIssues(ids: trimmed, apiKey: key)
    },
    assignToMe: { issueUUID in
      let trimmed = issueUUID.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return nil }
      guard let key = LinearLive.currentAPIKey() else { throw LinearClientError.missingAPIKey }
      return try await LinearLive.assignToMe(issueUUID: trimmed, apiKey: key)
    },
    startProgress: { issueUUID in
      let trimmed = issueUUID.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return nil }
      guard let key = LinearLive.currentAPIKey() else { throw LinearClientError.missingAPIKey }
      return try await LinearLive.startProgress(issueUUID: trimmed, apiKey: key)
    },
    fetchRecentIssues: { limit, teamKeys in
      guard let key = LinearLive.currentAPIKey() else { throw LinearClientError.missingAPIKey }
      let normalized = parseLinearTeamKeys(teamKeys.joined(separator: ",")).sorted()
      guard !normalized.isEmpty else { throw LinearClientError.missingTeamScope }
      return try await LinearLive.fetchRecentIssues(limit: max(1, limit), teamKeys: normalized, apiKey: key)
    }
  )

  static let testValue = Self(
    fetchIssueNaming: { _ in nil },
    fetchIssues: { _ in [] },
    assignToMe: { _ in nil },
    startProgress: { _ in nil },
    fetchRecentIssues: { _, _ in [] }
  )
}

extension DependencyValues {
  var linearClient: LinearClient {
    get { self[LinearClient.self] }
    set { self[LinearClient.self] = newValue }
  }
}

private nonisolated enum LinearLive {
  static let endpoint = URL(string: "https://api.linear.app/graphql")!

  /// GraphQL selection set shared by the batch query and the assign
  /// mutation so both return the same `LinearIssue` shape.
  static let issueFields =
    "id identifier title description url createdAt completedAt canceledAt "
    + "state { name type } assignee { displayName isMe } creator { displayName } "
    + "parent { identifier title }"

  static func currentAPIKey() -> String? {
    let key = UserDefaults.standard.string(forKey: "supacool.linear.apiKey") ?? ""
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  // MARK: Requests

  static func fetchIssueNaming(id: String, apiKey: String) async throws -> LinearIssueNaming? {
    let data = try await post(
      query: "query IssueNaming($id: String!) { issue(id: $id) { title branchName } }",
      variables: ["id": id],
      apiKey: apiKey
    )
    // Linear returns `{ data: { issue: null } }` when the id doesn't
    // resolve; surface that as a `nil` result rather than an error so
    // the sheet stays quiet on typos.
    guard let issue = data["issue"] as? [String: Any] else { return nil }
    guard let title = issue["title"] as? String else { throw LinearClientError.invalidResponse }
    let branchName = (issue["branchName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    return LinearIssueNaming(
      title: title.trimmingCharacters(in: .whitespacesAndNewlines),
      branchName: (branchName?.isEmpty == false) ? branchName : nil
    )
  }

  static func fetchIssues(ids: [String], apiKey: String) async throws -> [LinearIssue] {
    // Build one aliased query (`i0: issue(id: $id0) { … }`) with a
    // variable per id — keeps the request injection-safe and avoids N
    // round-trips for a pasted list.
    var varDefs: [String] = []
    var selections: [String] = []
    var variables: [String: Any] = [:]
    for (index, id) in ids.enumerated() {
      let varName = "id\(index)"
      varDefs.append("$\(varName): String!")
      selections.append("i\(index): issue(id: $\(varName)) { \(issueFields) }")
      variables[varName] = id
    }
    let query = "query Issues(\(varDefs.joined(separator: ", "))) { \(selections.joined(separator: " ")) }"

    let data = try await post(query: query, variables: variables, apiKey: apiKey)

    var result: [LinearIssue] = []
    for index in ids.indices {
      guard let raw = data["i\(index)"] as? [String: Any], let issue = parseIssue(raw) else { continue }
      result.append(issue)
    }
    return result
  }

  static func fetchRecentIssues(limit: Int, teamKeys: [String], apiKey: String) async throws -> [LinearIssue] {
    // `orderBy: createdAt` returns newest-first, filtered server-side to the
    // caller-supplied team keys (e.g. `CEN`). The keys come from per-repo
    // `RepositorySettings.linearTeamKeys`; the caller refuses an empty set so
    // a multi-team workspace can't trigger an org-wide query.
    let query =
      "query RecentIssues($first: Int!, $teamKeys: [String!]) { "
      + "issues(first: $first, orderBy: createdAt, filter: { team: { key: { in: $teamKeys } } }) "
      + "{ nodes { \(issueFields) } } }"
    let variables: [String: Any] = ["first": limit, "teamKeys": teamKeys]

    let data = try await post(query: query, variables: variables, apiKey: apiKey)
    guard
      let issues = data["issues"] as? [String: Any],
      let nodes = issues["nodes"] as? [[String: Any]]
    else {
      throw LinearClientError.invalidResponse
    }
    return nodes.compactMap(parseIssue)
  }

  static func assignToMe(issueUUID: String, apiKey: String) async throws -> LinearIssue? {
    let viewerData = try await post(query: "query { viewer { id } }", variables: [:], apiKey: apiKey)
    guard
      let viewer = viewerData["viewer"] as? [String: Any],
      let viewerID = viewer["id"] as? String
    else {
      throw LinearClientError.invalidResponse
    }

    let mutation =
      "mutation Assign($id: String!, $assigneeId: String!) { "
      + "issueUpdate(id: $id, input: { assigneeId: $assigneeId }) { success issue { \(issueFields) } } }"
    let data = try await post(
      query: mutation,
      variables: ["id": issueUUID, "assigneeId": viewerID],
      apiKey: apiKey
    )
    guard
      let result = data["issueUpdate"] as? [String: Any],
      let issue = result["issue"] as? [String: Any]
    else {
      return nil
    }
    return parseIssue(issue)
  }

  static func startProgress(issueUUID: String, apiKey: String) async throws -> LinearIssue? {
    // Pull the issue plus its team's workflow states in one round-trip: the
    // `started` state to move into lives on the team, and we need the current
    // state to stay idempotent.
    let query =
      "query Progress($id: String!) { issue(id: $id) { \(issueFields) "
      + "team { states { nodes { id name type position } } } } }"
    let lookup = try await post(query: query, variables: ["id": issueUUID], apiKey: apiKey)
    guard let issueDict = lookup["issue"] as? [String: Any] else {
      throw LinearClientError.notFound(issueUUID)
    }
    let current = parseIssue(issueDict)
    // Already being worked (In Progress / In Review) — leave it alone.
    if current?.stateType == "started" { return current }

    guard
      let team = issueDict["team"] as? [String: Any],
      let states = team["states"] as? [String: Any],
      let nodes = states["nodes"] as? [[String: Any]]
    else {
      throw LinearClientError.invalidResponse
    }
    let workflowStates = nodes.map {
      LinearClient.WorkflowState(
        id: $0["id"] as? String ?? "",
        name: $0["name"] as? String ?? "",
        type: $0["type"] as? String ?? "",
        position: ($0["position"] as? Double) ?? .greatestFiniteMagnitude
      )
    }
    guard let targetID = LinearClient.canonicalStartedStateID(from: workflowStates) else {
      throw LinearClientError.invalidResponse
    }

    let mutation =
      "mutation Start($id: String!, $stateId: String!) { "
      + "issueUpdate(id: $id, input: { stateId: $stateId }) { success issue { \(issueFields) } } }"
    let data = try await post(
      query: mutation,
      variables: ["id": issueUUID, "stateId": targetID],
      apiKey: apiKey
    )
    guard
      let result = data["issueUpdate"] as? [String: Any],
      let issue = result["issue"] as? [String: Any]
    else {
      return nil
    }
    return parseIssue(issue)
  }

  // MARK: Plumbing

  /// POSTs a GraphQL operation and returns the `data` payload, translating
  /// HTTP and GraphQL-level errors into `LinearClientError`.
  static func post(query: String, variables: [String: Any], apiKey: String) async throws -> [String: Any] {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(apiKey, forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
    request.timeoutInterval = 15

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw LinearClientError.invalidResponse
    }
    if http.statusCode == 401 || http.statusCode == 403 {
      throw LinearClientError.unauthorized
    }
    guard (200..<300).contains(http.statusCode) else {
      let bodyText = String(data: data, encoding: .utf8) ?? ""
      throw LinearClientError.requestFailed(status: http.statusCode, body: bodyText)
    }
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw LinearClientError.invalidResponse
    }
    if let errors = json["errors"] as? [[String: Any]], !errors.isEmpty {
      let messages = errors.compactMap { $0["message"] as? String }.joined(separator: "; ")
      // GraphQL surfaces "Entity not found" as a normal errors entry rather
      // than a 4xx — translate so callers can drop a missing-id quietly.
      if messages.localizedCaseInsensitiveContains("not found") {
        throw LinearClientError.notFound("")
      }
      throw LinearClientError.requestFailed(status: http.statusCode, body: messages)
    }
    guard let payload = json["data"] as? [String: Any] else {
      throw LinearClientError.invalidResponse
    }
    return payload
  }

  static func parseIssue(_ dict: [String: Any]) -> LinearIssue? {
    guard
      let id = dict["id"] as? String,
      let identifier = dict["identifier"] as? String,
      let title = dict["title"] as? String
    else {
      return nil
    }
    let state = dict["state"] as? [String: Any]
    let assignee = dict["assignee"] as? [String: Any]
    let creator = dict["creator"] as? [String: Any]
    let parent = dict["parent"] as? [String: Any]
    return LinearIssue(
      id: id,
      identifier: identifier,
      title: title.trimmingCharacters(in: .whitespacesAndNewlines),
      description: (dict["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
      stateName: state?["name"] as? String,
      stateType: state?["type"] as? String,
      assigneeName: assignee?["displayName"] as? String,
      assignedToMe: (assignee?["isMe"] as? Bool) ?? false,
      creatorName: creator?["displayName"] as? String,
      url: dict["url"] as? String,
      createdAt: parseISODate(dict["createdAt"]),
      completedAt: parseISODate(dict["completedAt"]),
      canceledAt: parseISODate(dict["canceledAt"]),
      parentIdentifier: parent?["identifier"] as? String,
      parentTitle: (parent?["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    )
  }

  /// Linear timestamps arrive as ISO-8601 with fractional seconds
  /// (`2026-06-09T18:00:00.000Z`); accept the plain form too.
  static func parseISODate(_ raw: Any?) -> Date? {
    guard let string = raw as? String else { return nil }
    if let date = try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
      return date
    }
    return try? Date(string, strategy: .iso8601)
  }
}

// MARK: - Ticket id detection

/// Extracts the first Linear-style ticket id (e.g. `CEN-6690`) from a
/// prompt string. Returns `nil` when none is found.
nonisolated func firstLinearTicketID(in text: String) -> String? {
  linearTicketIDs(in: text).first
}

/// Extracts ALL Linear-style ticket ids from arbitrary text — pasted
/// issue URLs (`linear.app/<org>/issue/CEN-7404/slug`) as well as bare
/// ids — de-duplicated, preserving first-seen order. Detection is
/// prefix-agnostic: explicit pastes and prompt-driven branch naming accept any
/// uppercase prefix. Team-key scoping applies only to the recent-ticket import
/// and to transcript chip parsing.
nonisolated func linearTicketIDs(in text: String) -> [String] {
  guard !text.isEmpty else { return [] }
  let regex = /\b([A-Z][A-Z0-9]{1,9}-\d+)\b/
  var seen: Set<String> = []
  var result: [String] = []
  for match in text.matches(of: regex) {
    let id = String(match.output.1)
    if seen.insert(id).inserted {
      result.append(id)
    }
  }
  return result
}

/// Normalizes a comma-separated list of Linear team keys (e.g. `"CEN, foo"`)
/// into an upper-cased, de-duplicated set. Shared by the recent-ticket import
/// scope and the per-repo (`RepositorySettings.linearTeamKeys`) chip-parsing
/// allowlist.
nonisolated func parseLinearTeamKeys(_ raw: String?) -> Set<String> {
  let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else { return [] }
  return Set(
    trimmed
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
      .filter { !$0.isEmpty }
  )
}
