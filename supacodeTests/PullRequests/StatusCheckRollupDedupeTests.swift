import Testing

@testable import Supacool

/// Regression cover for the "N checks failed on a green PR" class of lie.
///
/// GitHub's rollup keeps every check run on the head commit, so a re-run leaves
/// the old failing run in the payload forever. Reproduced from
/// `centrumai/centrum_backend#4814`, which reported `2 checks failed` from a
/// superseded run 65 seconds before it merged green.
struct StatusCheckRollupDedupeTests {
  @Test func supersededFailingRunLosesToTheRerun() {
    let rollup = [
      check("Playwright Scenarios Checks", conclusion: "FAILURE", completedAt: "2026-07-29T00:36:17Z"),
      check("Playwright Scenarios Checks", conclusion: "SKIPPED", completedAt: "2026-07-29T00:44:42Z"),
      check("PR Gate", conclusion: "FAILURE", completedAt: "2026-07-29T00:41:11Z"),
      check("PR Gate", conclusion: "SUCCESS", completedAt: "2026-07-29T00:44:52Z"),
    ]

    let latest = rollup.latestRunPerCheck

    #expect(latest.count == 2)
    #expect(PullRequestCheckBreakdown(checks: latest).failed == 0)
    #expect(BoardPullRequestChecks.outcome(checks: latest) == .completed(allPassed: true))
  }

  @Test func rerunGreenPullRequestIsNoLongerClassifiedAsCiFailed() {
    let rollup = [
      check("PR Gate", conclusion: "FAILURE", completedAt: "2026-07-29T00:41:11Z"),
      check("PR Gate", conclusion: "SUCCESS", completedAt: "2026-07-29T00:44:52Z"),
    ]

    let snapshot = PullRequestSnapshot(
      state: .open,
      title: "CEN-8667: Finish the connector bulk delete",
      statusChecks: rollup.latestRunPerCheck,
      greptileScore: 5
    )

    #expect(PRBallState(snapshot: snapshot) == .readyToMerge)
  }

  @Test func aStillFailingCheckSurvivesDeduping() {
    let rollup = [
      check("Unit Tests", conclusion: "SUCCESS", completedAt: "2026-07-29T00:36:17Z"),
      check("Unit Tests", conclusion: "FAILURE", completedAt: "2026-07-29T00:44:42Z"),
    ]

    let latest = rollup.latestRunPerCheck

    #expect(latest.count == 1)
    #expect(PullRequestCheckBreakdown(checks: latest).failed == 1)
  }

  @Test func sameJobNameInDifferentWorkflowsStaysDistinct() {
    let rollup = [
      check("lint", workflow: "CI", conclusion: "SUCCESS", completedAt: "2026-07-29T00:36:17Z"),
      check("lint", workflow: "Nightly", conclusion: "FAILURE", completedAt: "2026-07-29T00:44:42Z"),
    ]

    let latest = rollup.latestRunPerCheck

    #expect(latest.count == 2)
    #expect(PullRequestCheckBreakdown(checks: latest).failed == 1)
  }

  @Test func startTimeBreaksTiesWhenARunHasNotCompleted() {
    let rollup = [
      check("E2E Tests", conclusion: "FAILURE", completedAt: "2026-07-29T00:36:17Z"),
      GithubPullRequestStatusCheck(
        name: "E2E Tests",
        status: "IN_PROGRESS",
        workflowName: "CI",
        startedAt: "2026-07-29T00:44:30Z"
      ),
    ]

    let latest = rollup.latestRunPerCheck

    #expect(latest.count == 1)
    #expect(BoardPullRequestChecks.outcome(checks: latest) == .pending)
  }

  @Test func undatedEntriesFallBackToArrayOrder() {
    let rollup = [
      GithubPullRequestStatusCheck(name: "legacy", conclusion: "FAILURE"),
      GithubPullRequestStatusCheck(name: "legacy", conclusion: "SUCCESS"),
    ]

    let latest = rollup.latestRunPerCheck

    #expect(latest.count == 1)
    #expect(PullRequestCheckBreakdown(checks: latest).passed == 1)
  }

  @Test func aDatedRunIsNeverDisplacedByAnUndatedOne() {
    let rollup = [
      check("PR Gate", conclusion: "SUCCESS", completedAt: "2026-07-29T00:44:52Z"),
      GithubPullRequestStatusCheck(name: "PR Gate", conclusion: "FAILURE", workflowName: "CI"),
    ]

    let latest = rollup.latestRunPerCheck

    #expect(latest.count == 1)
    #expect(PullRequestCheckBreakdown(checks: latest).failed == 0)
  }

  @Test func survivingChecksKeepTheirFirstSeenOrder() {
    let rollup = [
      check("Unit Tests", conclusion: "SUCCESS", completedAt: "2026-07-29T00:36:00Z"),
      check("PR Gate", conclusion: "FAILURE", completedAt: "2026-07-29T00:41:11Z"),
      check("PR Gate", conclusion: "SUCCESS", completedAt: "2026-07-29T00:44:52Z"),
    ]

    #expect(rollup.latestRunPerCheck.map(\.displayName) == ["Unit Tests", "PR Gate"])
  }

  @Test func viewPipelineDedupesBeforeTheSnapshotReachesTheBoard() throws {
    let stdout = """
      {
        "state": "OPEN",
        "isDraft": false,
        "title": "CEN-8667: Finish the connector bulk delete",
        "updatedAt": "2026-07-29T00:45:00Z",
        "reviewDecision": null,
        "mergeable": "MERGEABLE",
        "mergeStateStatus": "CLEAN",
        "statusCheckRollup": [
          {
            "__typename": "CheckRun", "name": "PR Gate", "workflowName": "CI",
            "status": "COMPLETED", "conclusion": "FAILURE",
            "startedAt": "2026-07-29T00:41:08Z", "completedAt": "2026-07-29T00:41:11Z"
          },
          {
            "__typename": "CheckRun", "name": "PR Gate", "workflowName": "CI",
            "status": "COMPLETED", "conclusion": "SUCCESS",
            "startedAt": "2026-07-29T00:44:47Z", "completedAt": "2026-07-29T00:44:52Z"
          }
        ]
      }
      """

    let snapshot = try decodePullRequestSnapshot(stdout: stdout)

    #expect(snapshot.statusChecks.count == 1)
    #expect(PullRequestCheckBreakdown(checks: snapshot.statusChecks).failed == 0)
  }

  @Test func listPipelineDedupesBeforeTheSnapshotReachesPRPulse() throws {
    let stdout = """
      [
        {
          "number": 4814,
          "title": "CEN-8667: Finish the connector bulk delete",
          "url": "https://github.com/centrumai/centrum_backend/pull/4814",
          "author": { "login": "jzillmann" },
          "isDraft": false,
          "headRefName": "cen-8667",
          "updatedAt": "2026-07-29T00:45:00Z",
          "reviewDecision": null,
          "mergeable": "MERGEABLE",
          "mergeStateStatus": "CLEAN",
          "statusCheckRollup": [
            {
              "__typename": "CheckRun", "name": "Playwright Scenarios Checks", "workflowName": "CI",
              "status": "COMPLETED", "conclusion": "FAILURE",
              "startedAt": "2026-07-29T00:33:32Z", "completedAt": "2026-07-29T00:36:17Z"
            },
            {
              "__typename": "CheckRun", "name": "Playwright Scenarios Checks", "workflowName": "CI",
              "status": "COMPLETED", "conclusion": "SKIPPED",
              "startedAt": "2026-07-29T00:44:43Z", "completedAt": "2026-07-29T00:44:42Z"
            }
          ]
        }
      ]
      """

    let pullRequests = try decodeOpenPullRequests(stdout: stdout)

    #expect(pullRequests.count == 1)
    #expect(pullRequests[0].statusChecks.count == 1)
    #expect(pullRequests[0].checks.failed == 0)
  }
}

private func check(
  _ name: String,
  workflow: String = "CI",
  conclusion: String,
  completedAt: String
) -> GithubPullRequestStatusCheck {
  GithubPullRequestStatusCheck(
    name: name,
    status: "COMPLETED",
    conclusion: conclusion,
    workflowName: workflow,
    startedAt: completedAt,
    completedAt: completedAt
  )
}
