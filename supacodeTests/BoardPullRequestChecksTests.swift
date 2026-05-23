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
}

private func makePullRequest(
  state: String = "OPEN",
  isDraft: Bool = false,
  reviewDecision: String? = nil,
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
    mergeStateStatus: nil,
    updatedAt: nil,
    url: "https://example.com/pull/42",
    headRefName: "feature",
    baseRefName: "main",
    commitsCount: 1,
    authorLogin: "comandante",
    statusCheckRollup: checks.isEmpty ? nil : GithubPullRequestStatusCheckRollup(checks: checks)
  )
}
