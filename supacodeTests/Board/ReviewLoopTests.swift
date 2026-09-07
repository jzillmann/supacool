import Foundation
import Testing

@testable import Supacool

@MainActor
struct ReviewLoopTests {
  @Test func stateRoundTrips() throws {
    let reviewerID = UUID()
    let started = Date(timeIntervalSince1970: 1_750_000_000)
    let state = ReviewLoopState(
      reviewerTerminalID: reviewerID,
      pullRequestURL: "https://github.com/acme/widgets/pull/42",
      phase: .needsDecision,
      round: 5,
      maximumRounds: 5,
      expectedReviewSHA: "def456",
      lastReviewedSHA: "abc123",
      lastSummary: "The same boundary keeps failing.",
      lastReport: "SUPACOOL_REVIEW_RESULT {…}",
      repeatedFindingsCount: 3,
      convergenceWarning: true,
      escalationReason: "Repeated findings after the configured round limit.",
      startedAt: started,
      updatedAt: started.addingTimeInterval(60),
    )

    let decoded = try JSONDecoder().decode(
      ReviewLoopState.self,
      from: JSONEncoder().encode(state)
    )
    #expect(decoded == state)
  }

  @Test func missingStateKeysUseSafeDefaults() throws {
    let json = "{}"
    let decoded = try JSONDecoder().decode(ReviewLoopState.self, from: Data(json.utf8))

    #expect(decoded.reviewerTerminalID == nil)
    #expect(decoded.pullRequestURL == nil)
    #expect(decoded.phase == .reviewing)
    #expect(decoded.round == 1)
    #expect(decoded.maximumRounds == 5)
    #expect(decoded.expectedReviewSHA == nil)
    #expect(decoded.lastReviewedSHA == nil)
    #expect(decoded.repeatedFindingsCount == 0)
    #expect(decoded.convergenceWarning == false)
    #expect(decoded.escalationReason == nil)
  }

  @Test func reportParserExtractsPayloadFromFinalMessage() {
    let report = ReviewLoopReportParser.parse(
      "I finished the review.\nSUPACOOL_REVIEW_RESULT\n" + "{\"verdict\":\"changes\",\"reviewed_sha\":\"abc123\","
        + "\"summary\":\"Needs a guard.\",\"findings\":[\"Missing guard\"]}"
    )

    #expect(
      report
        == ReviewLoopReport(
          verdict: .changes,
          reviewedSHA: "abc123",
          summary: "Needs a guard.",
          findings: ["Missing guard"],
        ))
  }

  @Test func reportParserHandlesNestedJSONAndCodeFence() {
    let report = ReviewLoopReportParser.parse(
      "SUPACOOL_REVIEW_RESULT ```json\n" + "{\"verdict\":\"pass\",\"reviewed_sha\":\"def456\","
        + "\"summary\":\"Looks good.\",\"findings\":[]}\n``` trailing text"
    )

    #expect(report?.verdict == .pass)
    #expect(report?.reviewedSHA == "def456")
    #expect(report?.findings.isEmpty == true)
  }

  @Test func malformedOrMissingReportsReturnNil() {
    #expect(ReviewLoopReportParser.parse("No marker here") == nil)
    #expect(ReviewLoopReportParser.parse("SUPACOOL_REVIEW_RESULT {not json}") == nil)
    #expect(ReviewLoopReportParser.parse("SUPACOOL_REVIEW_RESULT {\"verdict\":\"pass\"") == nil)
    #expect(
      ReviewLoopReportParser.parse(
        "SUPACOOL_REVIEW_RESULT {\"verdict\":\"unknown\",\"reviewed_sha\":\"x\",\"summary\":\"x\",\"findings\":[]}"
      ) == nil
    )
  }
}
