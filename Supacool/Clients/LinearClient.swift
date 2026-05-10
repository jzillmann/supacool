import ComposableArchitecture
import Foundation

private nonisolated let linearClientLogger = SupaLogger("Supacool.Linear")

/// Minimal Linear API client used by the New Terminal sheet to fetch a
/// ticket title when the user types a Linear-style id (e.g. `CEN-6690`)
/// into the prompt. The title feeds both the auto-suggested branch name
/// and the session card's `displayName`, so a one-line "Fix CEN-6690"
/// prompt produces a meaningful card and branch instead of a literal
/// echo of the prompt.
///
/// API key lives in UserDefaults under `supacool.linear.apiKey`. Either
/// a Personal API Key (`lin_api_…`, sent raw in the `Authorization`
/// header per Linear's docs) or an OAuth bearer token works.
struct LinearClient: Sendable {
  /// Returns the issue title for the given Linear identifier, or `nil`
  /// when no API key is configured. Throws on network / API errors so
  /// callers can downgrade to a fallback (LLM-generated branch name).
  var fetchIssueTitle: @Sendable (_ id: String) async throws -> String?
}

nonisolated enum LinearClientError: LocalizedError {
  case invalidResponse
  case unauthorized
  case notFound(String)
  case requestFailed(status: Int, body: String)

  var errorDescription: String? {
    switch self {
    case .invalidResponse:
      return "Unexpected response from the Linear API."
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
      let key = UserDefaults.standard.string(forKey: "supacool.linear.apiKey") ?? ""
      let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmedKey.isEmpty else { return nil }
      return try await LinearLive.fetchIssueTitle(id: trimmed, apiKey: trimmedKey)
    }
  )

  static let testValue = Self(
    fetchIssueTitle: { _ in nil }
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

  static func fetchIssueTitle(id: String, apiKey: String) async throws -> String? {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(apiKey, forHTTPHeaderField: "Authorization")

    let query = "query IssueTitle($id: String!) { issue(id: $id) { title } }"
    let body: [String: Any] = [
      "query": query,
      "variables": ["id": id],
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    request.timeoutInterval = 10

    linearClientLogger.debug("Fetching Linear issue title for \(id)")

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
        throw LinearClientError.notFound(id)
      }
      throw LinearClientError.requestFailed(status: http.statusCode, body: messages)
    }
    guard
      let payload = json["data"] as? [String: Any],
      let issue = payload["issue"] as? [String: Any]
    else {
      // Linear returns `{ data: { issue: null } }` when the id doesn't
      // resolve; surface that as a `nil` result rather than an error so
      // the sheet stays quiet on typos.
      return nil
    }
    guard let title = issue["title"] as? String else {
      throw LinearClientError.invalidResponse
    }
    return title.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

// MARK: - Ticket id detection

/// Extracts the first Linear-style ticket id (e.g. `CEN-6690`) from a
/// prompt string, honouring the same `supacool.references.ticketPrefixes`
/// allowlist as `SessionReferenceScannerLive.scanText`. Returns `nil`
/// when no allowlisted id is found.
nonisolated func firstLinearTicketID(in text: String) -> String? {
  guard !text.isEmpty else { return nil }
  let regex = /\b([A-Z][A-Z0-9]{1,9}-\d+)\b/
  let allowed = loadTicketPrefixAllowlistForLinear()
  for match in text.matches(of: regex) {
    let id = String(match.output.1)
    if allowed.isEmpty {
      return id
    }
    let prefix = id.split(separator: "-").first.map(String.init) ?? ""
    if allowed.contains(prefix) {
      return id
    }
  }
  return nil
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
