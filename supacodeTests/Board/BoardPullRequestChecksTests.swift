import Foundation
import Testing

@testable import Supacool

struct BoardPullRequestChecksTests {
  @Test func inProgressCheckMeansWaiting() {
    let checks = [GithubPullRequestStatusCheck(name: "CI", status: "IN_PROGRESS")]
    #expect(BoardPullRequestChecks.isWaiting(checks: checks))
  }

  @Test func expectedStatusContextMeansWaiting() {
    let checks = [GithubPullRequestStatusCheck(name: "CI", state: "EXPECTED")]
    #expect(BoardPullRequestChecks.isWaiting(checks: checks))
  }

  @Test func passedChecksAreNotWaiting() {
    let checks = [GithubPullRequestStatusCheck(name: "CI", status: "COMPLETED", conclusion: "SUCCESS")]
    #expect(!BoardPullRequestChecks.isWaiting(checks: checks))
  }

  @Test func pendingChecksKeepWaitingEvenIfSiblingFailed() {
    // A sibling failure must not pull the card out of "Checks Pending"
    // while other checks are still running — the agent's mental model
    // is "wait until CI fully settles, then act on the red glow."
    let checks = [
      GithubPullRequestStatusCheck(name: "CI", status: "IN_PROGRESS"),
      GithubPullRequestStatusCheck(name: "Tests", status: "COMPLETED", conclusion: "FAILURE"),
    ]
    #expect(BoardPullRequestChecks.isWaiting(checks: checks))
  }

  @Test func allCompletedWithFailureIsNotWaiting() {
    let checks = [
      GithubPullRequestStatusCheck(name: "CI", status: "COMPLETED", conclusion: "SUCCESS"),
      GithubPullRequestStatusCheck(name: "Tests", status: "COMPLETED", conclusion: "FAILURE"),
    ]
    #expect(!BoardPullRequestChecks.isWaiting(checks: checks))
  }

  @Test func outcomeIsUnknownWithoutChecks() {
    #expect(BoardPullRequestChecks.outcome(checks: []) == .unknown)
  }

  @Test func outcomeIsPendingWhenAnyCheckIsInProgress() {
    let checks = [
      GithubPullRequestStatusCheck(name: "CI", status: "COMPLETED", conclusion: "SUCCESS"),
      GithubPullRequestStatusCheck(name: "Lint", status: "IN_PROGRESS"),
    ]
    #expect(BoardPullRequestChecks.outcome(checks: checks) == .pending)
  }

  @Test func outcomeIsCompletedAllPassedWhenEverythingGreen() {
    let checks = [
      GithubPullRequestStatusCheck(name: "CI", status: "COMPLETED", conclusion: "SUCCESS"),
      GithubPullRequestStatusCheck(name: "Lint", status: "COMPLETED", conclusion: "SKIPPED"),
    ]
    #expect(BoardPullRequestChecks.outcome(checks: checks) == .completed(allPassed: true))
  }

  @Test func outcomeIsCompletedWithFailureWhenAllDoneAndOneFailed() {
    let checks = [
      GithubPullRequestStatusCheck(name: "CI", status: "COMPLETED", conclusion: "SUCCESS"),
      GithubPullRequestStatusCheck(name: "Tests", status: "COMPLETED", conclusion: "FAILURE"),
    ]
    #expect(BoardPullRequestChecks.outcome(checks: checks) == .completed(allPassed: false))
  }

  // MARK: - isWaitingExternal

  @Test func waitingExternalTrueWhenChecksPending() {
    let pullRequest = makePullRequest(checks: [
      GithubPullRequestStatusCheck(name: "CI", status: "IN_PROGRESS"),
    ])
    #expect(BoardPullRequestChecks.isWaitingExternal(pullRequest))
  }

  @Test func waitingExternalTrueWhenReviewRequired() {
    let pullRequest = makePullRequest(reviewDecision: "REVIEW_REQUIRED")
    #expect(BoardPullRequestChecks.isWaitingExternal(pullRequest))
  }

  @Test func waitingExternalFalseWhenReviewApproved() {
    let pullRequest = makePullRequest(reviewDecision: "APPROVED")
    #expect(!BoardPullRequestChecks.isWaitingExternal(pullRequest))
  }

  @Test func waitingExternalFalseWhenChangesRequested() {
    let pullRequest = makePullRequest(reviewDecision: "CHANGES_REQUESTED")
    #expect(!BoardPullRequestChecks.isWaitingExternal(pullRequest))
  }

  @Test func waitingExternalFalseWhenDraftEvenIfReviewRequired() {
    let pullRequest = makePullRequest(isDraft: true, reviewDecision: "REVIEW_REQUIRED")
    #expect(!BoardPullRequestChecks.isWaitingExternal(pullRequest))
  }

  @Test func waitingExternalFalseWhenMerged() {
    let pullRequest = makePullRequest(state: "MERGED", reviewDecision: "REVIEW_REQUIRED")
    #expect(!BoardPullRequestChecks.isWaitingExternal(pullRequest))
  }

  @Test func waitingExternalFalseWhenNilPullRequest() {
    #expect(!BoardPullRequestChecks.isWaitingExternal(nil))
  }

  @Test func waitingExternalFalseWhenAllGreenAndReviewApproved() {
    let pullRequest = makePullRequest(
      reviewDecision: "APPROVED",
      checks: [GithubPullRequestStatusCheck(name: "CI", status: "COMPLETED", conclusion: "SUCCESS")]
    )
    #expect(!BoardPullRequestChecks.isWaitingExternal(pullRequest))
  }

  // MARK: - Required checks GitHub never put in the rollup

  @Test func blockedMergeWithOnlyGreenChecksReadsAsPending() {
    // centrumai/centrum_backend#5423: the rollup held one green Greptile run
    // while the required "PR Gate" context had never reported and the CI
    // workflow sat queued. github.com said "1 expected, 1 successful"; the
    // chip said all checks passed.
    let checks = [GithubPullRequestStatusCheck(name: "Greptile Review", status: "COMPLETED", conclusion: "SUCCESS")]
    let pullRequest = makePullRequest(mergeStateStatus: "BLOCKED", checks: checks)
    #expect(BoardPullRequestChecks.outcome(pullRequest) == .pending)
    #expect(BoardPullRequestChecks.isWaiting(pullRequest))
    #expect(BoardPullRequestChecks.isWaitingExternal(pullRequest))
  }

  @Test func blockedMergeWithNoChecksAtAllReadsAsPending() {
    let pullRequest = makePullRequest(mergeStateStatus: "BLOCKED")
    #expect(BoardPullRequestChecks.outcome(pullRequest) == .pending)
    #expect(BoardPullRequestChecks.isWaiting(pullRequest))
  }

  @Test func blockedMergeAwaitingReviewStillReportsChecksPassed() {
    // A missing review blocks the merge too. Reading that as a missing check
    // would hang a permanent clock on every PR awaiting a reviewer.
    let checks = [GithubPullRequestStatusCheck(name: "CI", status: "COMPLETED", conclusion: "SUCCESS")]
    let pullRequest = makePullRequest(
      reviewDecision: "REVIEW_REQUIRED",
      mergeStateStatus: "BLOCKED",
      checks: checks
    )
    #expect(BoardPullRequestChecks.outcome(pullRequest) == .completed(allPassed: true))
    #expect(!BoardPullRequestChecks.isWaiting(pullRequest))
    // Still external — the reviewer owns the next move.
    #expect(BoardPullRequestChecks.isWaitingExternal(pullRequest))
  }

  @Test func blockedMergeWithChangesRequestedStillReportsChecksPassed() {
    let checks = [GithubPullRequestStatusCheck(name: "CI", status: "COMPLETED", conclusion: "SUCCESS")]
    let pullRequest = makePullRequest(
      reviewDecision: "CHANGES_REQUESTED",
      mergeStateStatus: "BLOCKED",
      checks: checks
    )
    #expect(BoardPullRequestChecks.outcome(pullRequest) == .completed(allPassed: true))
  }

  @Test func blockedMergeWithAFailedCheckStillReportsTheFailure() {
    // A red check is a settled verdict and explains the block on its own.
    let checks = [
      GithubPullRequestStatusCheck(name: "CI", status: "COMPLETED", conclusion: "FAILURE"),
    ]
    let pullRequest = makePullRequest(mergeStateStatus: "BLOCKED", checks: checks)
    #expect(BoardPullRequestChecks.outcome(pullRequest) == .completed(allPassed: false))
    #expect(!BoardPullRequestChecks.isWaiting(pullRequest))
  }

  @Test func cleanMergeStateKeepsGreenChecksGreen() {
    let checks = [GithubPullRequestStatusCheck(name: "CI", status: "COMPLETED", conclusion: "SUCCESS")]
    let pullRequest = makePullRequest(mergeStateStatus: "CLEAN", checks: checks)
    #expect(BoardPullRequestChecks.outcome(pullRequest) == .completed(allPassed: true))
    #expect(!BoardPullRequestChecks.isWaiting(pullRequest))
  }
}

private func makePullRequest(
  state: String = "OPEN",
  isDraft: Bool = false,
  reviewDecision: String? = nil,
  mergeStateStatus: String? = nil,
  checks: [GithubPullRequestStatusCheck] = []
) -> GithubPullRequest {
  GithubPullRequest(
    number: 42,
    title: "Test PR",
    state: state,
    additions: 0,
    deletions: 0,
    isDraft: isDraft,
    reviewDecision: reviewDecision,
    mergeable: nil,
    mergeStateStatus: mergeStateStatus,
    updatedAt: nil,
    url: "https://example.com/pull/42",
    headRefName: "feature",
    baseRefName: "main",
    commitsCount: 1,
    authorLogin: "comandante",
    statusCheckRollup: checks.isEmpty ? nil : GithubPullRequestStatusCheckRollup(checks: checks)
  )
}
