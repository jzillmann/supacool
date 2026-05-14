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
}
