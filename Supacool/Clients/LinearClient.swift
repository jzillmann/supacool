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
  /// Canonical web URL for the issue.
  var url: String?
  /// When Linear marked the issue completed / canceled. Drives the
  /// inbox's auto-drop of stale done tickets.
  var completedAt: Date? = nil
  var canceledAt: Date? = nil
}

/// Minimal Linear API client. Originally just fetched a single issue title
/// for the New Terminal sheet (typing `CEN-6690` into the prompt seeds the
/// branch name and card `displayName`). Extended for the Linear Inbox to
/// batch-fetch issues and assign them to the current user.
///
/// API key lives in UserDefaults under `supacool.linear.apiKey`. Either
/// a Personal API Key (`lin_api_…`, sent raw in the `Authorization`
/// header per Linear's docs) or an OAuth bearer token works.
struct LinearClient: Sendable {
  /// Returns the issue title for the given Linear identifier, or `nil`
  /// when no API key is configured. Throws on network / API errors so
  /// callers can downgrade to a fallback (LLM-generated branch name).
  var fetchIssueTitle: @Sendable (_ id: String) async throws -> String?

  /// Batch-fetches full issue records for the given identifiers (e.g.
  /// `["CEN-7404", "CEN-7405"]`). Identifiers that don't resolve are
  /// silently dropped, so the result may be shorter than the input and
  /// in a different order — match back by `identifier`. Throws
  /// `.missingAPIKey` when no key is configured so the inbox can prompt.
  var fetchIssues: @Sendable (_ ids: [String]) async throws -> [LinearIssue]

  /// Assigns the issue (by Linear UUID) to the current API-key holder and
  /// returns the updated record. Throws `.missingAPIKey` when unconfigured.
  var assignToMe: @Sendable (_ issueUUID: String) async throws -> LinearIssue?

  /// Fetches the most recently created issues, newest first. Always scoped
  /// to the `supacool.references.ticketPrefixes` team keys so a multi-team
  /// workspace can't flood the inbox — throws `.missingTeamScope` when the
  /// allowlist is empty rather than falling back to an org-wide query.
  /// Throws `.missingAPIKey` when no key is configured so the inbox can prompt.
  var fetchRecentIssues: @Sendable (_ limit: Int) async throws -> [LinearIssue]
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
      return "No ticket prefix configured. Add your team key (e.g. CEN) under "
        + "Settings → Linear → Ticket prefix allowlist so the import only pulls your team's tickets."
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
    fetchIssueTitle: { id in
      let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return nil }
      // Title lookup is best-effort: a missing key downgrades to nil so
      // the New Terminal sheet falls back to its LLM branch name.
      guard let key = LinearLive.currentAPIKey() else { return nil }
      return try await LinearLive.fetchIssueTitle(id: trimmed, apiKey: key)
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
    fetchRecentIssues: { limit in
      guard let key = LinearLive.currentAPIKey() else { throw LinearClientError.missingAPIKey }
      return try await LinearLive.fetchRecentIssues(limit: max(1, limit), apiKey: key)
    }
  )

  static let testValue = Self(
    fetchIssueTitle: { _ in nil },
    fetchIssues: { _ in [] },
    assignToMe: { _ in nil },
    fetchRecentIssues: { _ in [] }
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
    "id identifier title description url completedAt canceledAt "
    + "state { name type } assignee { displayName isMe }"

  static func currentAPIKey() -> String? {
    let key = UserDefaults.standard.string(forKey: "supacool.linear.apiKey") ?? ""
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  // MARK: Requests

  static func fetchIssueTitle(id: String, apiKey: String) async throws -> String? {
    let data = try await post(
      query: "query IssueTitle($id: String!) { issue(id: $id) { title } }",
      variables: ["id": id],
      apiKey: apiKey
    )
    // Linear returns `{ data: { issue: null } }` when the id doesn't
    // resolve; surface that as a `nil` result rather than an error so
    // the sheet stays quiet on typos.
    guard let issue = data["issue"] as? [String: Any] else { return nil }
    guard let title = issue["title"] as? String else { throw LinearClientError.invalidResponse }
    return title.trimmingCharacters(in: .whitespacesAndNewlines)
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

  static func fetchRecentIssues(limit: Int, apiKey: String) async throws -> [LinearIssue] {
    // `orderBy: createdAt` returns newest-first. The ticket-prefix
    // allowlist doubles as a team-key filter (prefixes ARE team keys,
    // e.g. `CEN`), applied server-side. An empty allowlist would mean an
    // org-wide query, which floods the inbox in a multi-team workspace —
    // refuse instead so the inbox can prompt for configuration.
    let teamKeys = loadTicketPrefixAllowlistForLinear().sorted()
    guard !teamKeys.isEmpty else { throw LinearClientError.missingTeamScope }
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
    return LinearIssue(
      id: id,
      identifier: identifier,
      title: title.trimmingCharacters(in: .whitespacesAndNewlines),
      description: (dict["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
      stateName: state?["name"] as? String,
      stateType: state?["type"] as? String,
      assigneeName: assignee?["displayName"] as? String,
      assignedToMe: (assignee?["isMe"] as? Bool) ?? false,
      url: dict["url"] as? String,
      completedAt: parseISODate(dict["completedAt"]),
      canceledAt: parseISODate(dict["canceledAt"])
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
/// prompt string, honouring the same `supacool.references.ticketPrefixes`
/// allowlist as `SessionReferenceScannerLive.scanText`. Returns `nil`
/// when no allowlisted id is found.
nonisolated func firstLinearTicketID(in text: String) -> String? {
  linearTicketIDs(in: text).first
}

/// Extracts ALL Linear-style ticket ids from arbitrary text — pasted
/// issue URLs (`linear.app/<org>/issue/CEN-7404/slug`) as well as bare
/// ids — de-duplicated, preserving first-seen order. Honours the
/// `supacool.references.ticketPrefixes` allowlist when set.
nonisolated func linearTicketIDs(in text: String) -> [String] {
  guard !text.isEmpty else { return [] }
  let regex = /\b([A-Z][A-Z0-9]{1,9}-\d+)\b/
  let allowed = loadTicketPrefixAllowlistForLinear()
  var seen: Set<String> = []
  var result: [String] = []
  for match in text.matches(of: regex) {
    let id = String(match.output.1)
    if !allowed.isEmpty {
      let prefix = id.split(separator: "-").first.map(String.init) ?? ""
      guard allowed.contains(prefix) else { continue }
    }
    if seen.insert(id).inserted {
      result.append(id)
    }
  }
  return result
}

private nonisolated func loadTicketPrefixAllowlistForLinear() -> Set<String> {
  let raw = UserDefaults.standard.string(forKey: "supacool.references.ticketPrefixes") ?? ""
  let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else { return [] }
  return Set(
    trimmed
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
      .filter { !$0.isEmpty }
  )
}
