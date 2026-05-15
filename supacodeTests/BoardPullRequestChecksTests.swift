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

  @Test func failedChecksAreActionableNotWaiting() {
    let checks = [
      GithubPullRequestStatusCheck(name: "CI", status: "IN_PROGRESS"),
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
}
