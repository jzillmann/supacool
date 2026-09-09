import Foundation

/// The durable phase of a pull-request review loop.
nonisolated enum ReviewLoopPhase: String, Codable, Hashable, Sendable {
  case reviewing
  case fixing
  case diagnosing
  case needsDecision
  case passed
  case stopped
}

/// State persisted alongside a session while an explicitly armed review loop
/// is running. The dates are intentionally part of the snapshot so a loop can
/// be inspected after relaunch without relying on live terminal state.
nonisolated struct ReviewLoopState: Codable, Hashable, Sendable {
  var reviewerTerminalID: UUID?
  var pullRequestURL: String?
  var phase: ReviewLoopPhase
  var round: Int
  var maximumRounds: Int
  /// The commit the next reviewer turn must report. Nil for the first
  /// round, where the PR head is discovered by the reviewer itself.
  var expectedReviewSHA: String?
  var lastReviewedSHA: String?
  var lastSummary: String?
  var lastReport: String?
  var lastFindingsFingerprint: String?
  var repeatedFindingsCount: Int
  var convergenceWarning: Bool
  var escalationReason: String?
  var startedAt: Date
  var updatedAt: Date

  init(
    reviewerTerminalID: UUID? = nil,
    pullRequestURL: String? = nil,
    phase: ReviewLoopPhase = .reviewing,
    round: Int = 1,
    maximumRounds: Int = 5,
    expectedReviewSHA: String? = nil,
    lastReviewedSHA: String? = nil,
    lastSummary: String? = nil,
    lastReport: String? = nil,
    lastFindingsFingerprint: String? = nil,
    repeatedFindingsCount: Int = 0,
    convergenceWarning: Bool = false,
    escalationReason: String? = nil,
    startedAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.reviewerTerminalID = reviewerTerminalID
    self.pullRequestURL = pullRequestURL
    self.phase = phase
    self.round = round
    self.maximumRounds = maximumRounds
    self.expectedReviewSHA = expectedReviewSHA
    self.lastReviewedSHA = lastReviewedSHA
    self.lastSummary = lastSummary
    self.lastReport = lastReport
    self.lastFindingsFingerprint = lastFindingsFingerprint
    self.repeatedFindingsCount = repeatedFindingsCount
    self.convergenceWarning = convergenceWarning
    self.escalationReason = escalationReason
    self.startedAt = startedAt
    self.updatedAt = updatedAt
  }

  enum CodingKeys: String, CodingKey {
    case reviewerTerminalID, pullRequestURL, phase, round, maximumRounds
    case expectedReviewSHA, lastReviewedSHA, lastSummary, lastReport, lastFindingsFingerprint
    case repeatedFindingsCount
    case convergenceWarning, escalationReason, startedAt, updatedAt
  }

  // Persisted types must default every non-identity field when loading an
  // older session snapshot. See docs/agent-guides/persistence.md.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    reviewerTerminalID = try c.decodeIfPresent(UUID.self, forKey: .reviewerTerminalID)
    pullRequestURL = try c.decodeIfPresent(String.self, forKey: .pullRequestURL)
    phase = (try? c.decodeIfPresent(ReviewLoopPhase.self, forKey: .phase)) ?? .reviewing
    round = try c.decodeIfPresent(Int.self, forKey: .round) ?? 1
    maximumRounds = try c.decodeIfPresent(Int.self, forKey: .maximumRounds) ?? 5
    expectedReviewSHA = try c.decodeIfPresent(String.self, forKey: .expectedReviewSHA)
    lastReviewedSHA = try c.decodeIfPresent(String.self, forKey: .lastReviewedSHA)
    lastSummary = try c.decodeIfPresent(String.self, forKey: .lastSummary)
    lastReport = try c.decodeIfPresent(String.self, forKey: .lastReport)
    lastFindingsFingerprint = try c.decodeIfPresent(String.self, forKey: .lastFindingsFingerprint)
    repeatedFindingsCount = try c.decodeIfPresent(Int.self, forKey: .repeatedFindingsCount) ?? 0
    convergenceWarning = try c.decodeIfPresent(Bool.self, forKey: .convergenceWarning) ?? false
    escalationReason = try c.decodeIfPresent(String.self, forKey: .escalationReason)
    startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date()
    updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? startedAt
  }
}

extension ReviewLoopState {
  /// The findings of the last stored reviewer handoff, whatever its verdict.
  /// Empty when no report is stored or the report does not parse — the
  /// re-review prompt then falls back to the summary alone.
  var lastFindings: [String] {
    lastReport.flatMap(ReviewLoopReportParser.parse)?.findings ?? []
  }

  /// The last stored handoff when it still carries work for the
  /// implementation agent. `blocked` counts: a blocked verdict parks the loop
  /// for a human, but once the human says continue, the findings belong with
  /// the agent, not with another read-only pass over the same commit.
  /// `pass` reports and reports without findings are nil.
  var pendingFixReport: ReviewLoopReport? {
    guard let report = lastReport.flatMap(ReviewLoopReportParser.parse),
      report.verdict != .pass,
      !report.findings.isEmpty
    else { return nil }
    return report
  }
}

nonisolated enum ReviewLoopVerdict: String, Codable, Equatable, Sendable {
  case pass
  case changes
  case blocked
}

/// The structured payload emitted by the reviewer. This is deliberately not
/// persisted; `lastReport` stores the original final message for inspection.
nonisolated struct ReviewLoopReport: Codable, Equatable, Sendable {
  let verdict: ReviewLoopVerdict
  let reviewedSHA: String
  let summary: String
  let findings: [String]

  enum CodingKeys: String, CodingKey {
    case verdict
    case reviewedSHA = "reviewed_sha"
    case summary, findings
  }
}

enum ReviewLoopReportParser {
  static let marker = "SUPACOOL_REVIEW_RESULT"
  static let endMarker = "SUPACOOL_REVIEW_RESULT_END"

  /// Extracts a review handoff from a reviewer final message. New reviewers
  /// emit a bounded Markdown block; the original JSON contract remains
  /// supported so persisted and in-flight review loops survive upgrades.
  static func parse(_ message: String) -> ReviewLoopReport? {
    guard let markerRange = message.range(of: marker) else { return nil }
    let suffix = message[markerRange.upperBound...]
    if let markdownReport = parseMarkdown(suffix) {
      return markdownReport
    }
    return parseLegacyJSON(suffix)
  }

  private static func parseMarkdown(_ suffix: Substring) -> ReviewLoopReport? {
    guard let endRange = suffix.range(of: endMarker) else { return nil }
    let block = String(suffix[..<endRange.lowerBound])
      .replacing("\r\n", with: "\n")
    let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

    guard
      let verdictLine = lines.first(where: { hasPrefix($0, prefix: "Verdict:") }),
      let reviewedSHALine = lines.first(where: { hasPrefix($0, prefix: "Reviewed commit:") }),
      let summaryHeading = lines.firstIndex(where: { normalized($0) == "## summary" }),
      let findingsHeading = lines.firstIndex(where: { normalized($0) == "## findings" }),
      summaryHeading < findingsHeading
    else { return nil }

    let verdictValue = value(after: "Verdict:", in: verdictLine).lowercased()
    let verdict: ReviewLoopVerdict
    switch verdictValue {
    case "pass", "passed": verdict = .pass
    case "changes", "changes requested": verdict = .changes
    case "blocked": verdict = .blocked
    default: return nil
    }

    let reviewedSHA = value(after: "Reviewed commit:", in: reviewedSHALine)
      .trimmingCharacters(in: CharacterSet(charactersIn: "`"))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !reviewedSHA.isEmpty else { return nil }

    let summary = lines[(summaryHeading + 1)..<findingsHeading]
      .joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let findings = parseFindings(lines[(findingsHeading + 1)...])

    return ReviewLoopReport(
      verdict: verdict,
      reviewedSHA: reviewedSHA,
      summary: summary,
      findings: findings
    )
  }

  private static func parseLegacyJSON(_ suffix: Substring) -> ReviewLoopReport? {
    guard let start = suffix.firstIndex(of: "{") else { return nil }
    guard let end = endOfJSONObject(in: suffix, from: start) else { return nil }
    let json = String(suffix[start...end])
    guard let data = json.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(ReviewLoopReport.self, from: data)
  }

  private static func parseFindings(_ lines: ArraySlice<String>) -> [String] {
    var findings: [String] = []
    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty else { continue }
      if let finding = orderedListValue(trimmed) {
        findings.append(finding)
      } else if !findings.isEmpty {
        findings[findings.count - 1] += " " + trimmed
      }
    }
    if findings.count == 1,
      ["none", "none.", "no findings", "no findings."].contains(findings[0].lowercased())
    {
      return []
    }
    return findings
  }

  private static func orderedListValue(_ line: String) -> String? {
    guard let period = line.firstIndex(of: "."), period != line.startIndex else { return nil }
    let number = line[..<period]
    guard number.allSatisfy(\.isNumber) else { return nil }
    let valueStart = line.index(after: period)
    let value = line[valueStart...].trimmingCharacters(in: .whitespaces)
    return value.isEmpty ? nil : value
  }

  private static func normalized(_ line: String) -> String {
    line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private static func hasPrefix(_ line: String, prefix: String) -> Bool {
    normalized(line).hasPrefix(prefix.lowercased())
  }

  private static func value(after prefix: String, in line: String) -> String {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let range = trimmed.range(of: prefix, options: [.caseInsensitive, .anchored]) else { return "" }
    return trimmed[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func endOfJSONObject(
    in text: Substring,
    from start: Substring.Index
  ) -> Substring.Index? {
    var depth = 0
    var escaped = false
    var inString = false
    var index = start
    while index < text.endIndex {
      let character = text[index]
      if inString {
        if escaped {
          escaped = false
        } else if character == "\\" {
          escaped = true
        } else if character == "\"" {
          inString = false
        }
      } else {
        switch character {
        case "\"": inString = true
        case "{": depth += 1
        case "}":
          depth -= 1
          if depth == 0 { return index }
        default: break
        }
      }
      index = text.index(after: index)
    }
    return nil
  }
}
