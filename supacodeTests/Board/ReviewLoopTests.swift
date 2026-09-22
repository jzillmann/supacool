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
    #expect(decoded.additionalPullRequestURLs == [])
    #expect(decoded.pullRequestURLs == [])
    #expect(decoded.reviewSubject == "the current pull request")
    #expect(decoded.phase == .reviewing)
    #expect(decoded.round == 1)
    #expect(decoded.maximumRounds == 5)
    #expect(decoded.expectedReviewSHA == nil)
    #expect(decoded.lastReviewedSHA == nil)
    #expect(decoded.repeatedFindingsCount == 0)
    #expect(decoded.convergenceWarning == false)
    #expect(decoded.escalationReason == nil)
  }

  @Test func severalPullRequestsBecomeOneReviewSubject() {
    let single = ReviewLoopState(pullRequestURL: "https://github.com/acme/widgets/pull/42")
    #expect(single.reviewSubject == "https://github.com/acme/widgets/pull/42")

    let stacked = ReviewLoopState(
      pullRequestURL: "https://github.com/acme/widgets/pull/42",
      additionalPullRequestURLs: ["https://github.com/acme/widgets/pull/43"]
    )
    #expect(stacked.pullRequestURLs.count == 2)
    #expect(stacked.reviewSubject.hasPrefix("these pull requests together"))
    #expect(stacked.reviewSubject.contains("pull/42, https://github.com/acme/widgets/pull/43"))
  }

  @Test func onlyAFinishedOrParkedLoopCanRestart() {
    #expect(ReviewLoopState(phase: .passed).canRestart)
    #expect(ReviewLoopState(phase: .stopped).canRestart)
    #expect(ReviewLoopState(phase: .needsDecision).canRestart)
    #expect(!ReviewLoopState(phase: .reviewing).canRestart)
    #expect(!ReviewLoopState(phase: .fixing).canRestart)
    #expect(!ReviewLoopState(phase: .conferring).canRestart)
    #expect(!ReviewLoopState(phase: .diagnosing).canRestart)
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

  @Test func reportParserExtractsHumanReadableMarkdownHandoff() {
    let report = ReviewLoopReportParser.parse(
      """
      SUPACOOL_REVIEW_RESULT
      # Review handoff — copy this entire block

      Verdict: changes
      Reviewed commit: `abc123`

      ## Summary

      Two correctness issues remain.

      ## Findings

      1. Guard the empty response before indexing.
      2. Preserve the existing value
         when decoding an older snapshot.
      SUPACOOL_REVIEW_RESULT_END
      """
    )

    #expect(
      report
        == ReviewLoopReport(
          verdict: .changes,
          reviewedSHA: "abc123",
          summary: "Two correctness issues remain.",
          findings: [
            "Guard the empty response before indexing.",
            "Preserve the existing value when decoding an older snapshot.",
          ],
        ))
  }

  @Test func reportParserAcceptsDriftedReviewerFormats() {
    // Verbatim shape of two real Codex handoffs the strict parser rejected.
    let report = ReviewLoopReportParser.parse(
      """
      SUPACOOL_REVIEW_RESULT_START
      Verdict: changes
      PR: #5521
      Commit: faba198e0b874021c5348fa66b3d907482a00a2b

      Findings:

      1. [P1] Restored imported runs lose their solved state.
      - [P2] Reload coverage is missing.

      CI is green. Only the exact PR commit above was reviewed.
      SUPACOOL_REVIEW_RESULT_END
      """
    )

    #expect(
      report
        == ReviewLoopReport(
          verdict: .changes,
          reviewedSHA: "faba198e0b874021c5348fa66b3d907482a00a2b",
          summary: "",
          findings: [
            "[P1] Restored imported runs lose their solved state.",
            "[P2] Reload coverage is missing.",
          ],
        ))
  }

  @Test func reportParserReadsAnInlineSummary() {
    let report = ReviewLoopReportParser.parse(
      """
      SUPACOOL_REVIEW_RESULT
      Verdict: pass
      Reviewed commit: `def456`
      Summary: Ready to merge.
      Findings: none
      SUPACOOL_REVIEW_RESULT_END
      """
    )

    #expect(report?.verdict == .pass)
    #expect(report?.summary == "Ready to merge.")
    #expect(report?.findings == [])
  }

  @Test func reportParserTreatsNoFindingsAsAnEmptyList() {
    let report = ReviewLoopReportParser.parse(
      """
      SUPACOOL_REVIEW_RESULT
      # Review handoff — copy this entire block
      Verdict: pass
      Reviewed commit: `def456`
      ## Summary
      Ready to merge.
      ## Findings
      1. No findings.
      SUPACOOL_REVIEW_RESULT_END
      """
    )

    #expect(report?.verdict == .pass)
    #expect(report?.findings == [])
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
        "SUPACOOL_REVIEW_RESULT\nVerdict: pass\nReviewed commit: abc123\n## Summary\nDone\n## Findings\n1. None."
      ) == nil
    )
    #expect(
      ReviewLoopReportParser.parse(
        "SUPACOOL_REVIEW_RESULT {\"verdict\":\"unknown\",\"reviewed_sha\":\"x\",\"summary\":\"x\",\"findings\":[]}"
      ) == nil
    )
  }
}
