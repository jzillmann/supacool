import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import Supacool

// MARK: - Pure parsing / classification

struct GreptileScoreParserTests {
  @Test func extractsScoreFromGreptileSummary() {
    let body = "<h3>Greptile Summary</h3>\n\nTrims CI…\n\n<h3>Confidence Score: 5/5</h3>\n\nSafe to merge."
    #expect(GreptileScoreParser.score(in: body) == 5)
  }

  @Test func extractsLowScore() {
    #expect(GreptileScoreParser.score(in: "Confidence Score: 3/5") == 3)
  }

  @Test func toleratesSpacingAndCase() {
    #expect(GreptileScoreParser.score(in: "confidence score:  4 / 5") == 4)
  }

  @Test func returnsNilWithoutScore() {
    #expect(GreptileScoreParser.score(in: "Looks good to me!") == nil)
  }

  @Test func lastGreptileCommentWins() {
    let comments: [(login: String, body: String)] = [
      (login: "greptile-apps[bot]", body: "Confidence Score: 2/5"),
      (login: "jo", body: "Confidence Score: 1/5"),
      (login: "greptile-apps[bot]", body: "Confidence Score: 5/5"),
    ]
    #expect(GreptileScoreParser.score(fromComments: comments) == 5)
  }

  @Test func ignoresNonBotComments() {
    let comments: [(login: String, body: String)] = [
      (login: "jo", body: "Confidence Score: 1/5"),
    ]
    #expect(GreptileScoreParser.score(fromComments: comments) == nil)
  }
}

struct PRMonitorDecodingTests {
  @Test func decodesGhPrListOutput() throws {
    let json = """
      [
        {
          "number": 3807,
          "title": "Add pagination",
          "url": "https://github.com/acme/rocket/pull/3807",
          "author": { "login": "jo" },
          "isDraft": false,
          "headRefName": "cen-2462-pagination",
          "updatedAt": "2026-06-10T07:55:18Z",
          "reviewDecision": "",
          "statusCheckRollup": [
            { "__typename": "CheckRun", "status": "COMPLETED", "conclusion": "SUCCESS", "name": "build" },
            { "__typename": "CheckRun", "status": "COMPLETED", "conclusion": "FAILURE", "name": "test" },
            { "__typename": "StatusContext", "state": "PENDING", "context": "deploy" }
          ]
        }
      ]
      """
    let prs = try decodeOpenPullRequests(stdout: json)
    let pullRequest = try #require(prs.first)
    #expect(pullRequest.number == 3807)
    #expect(pullRequest.author == "jo")
    #expect(pullRequest.headRefName == "cen-2462-pagination")
    #expect(pullRequest.checks.passed == 1)
    #expect(pullRequest.checks.failed == 1)
    #expect(pullRequest.checks.inProgress == 1)
    // One check still pending → rollup is pending, not failed.
    #expect(pullRequest.ciOutcome == .pending)
    #expect(pullRequest.greptileScore == nil)
  }

  @Test func decodesEmptyRollup() throws {
    let json = """
      [
        {
          "number": 1,
          "title": "Docs",
          "url": "https://github.com/acme/rocket/pull/1",
          "author": null,
          "isDraft": true,
          "headRefName": "docs",
          "updatedAt": "2026-06-10T07:55:18Z",
          "reviewDecision": null,
          "statusCheckRollup": null
        }
      ]
      """
    let prs = try decodeOpenPullRequests(stdout: json)
    let pullRequest = try #require(prs.first)
    #expect(pullRequest.ciOutcome == .unknown)
    #expect(pullRequest.isDraft)
    #expect(pullRequest.author.isEmpty)
  }

  @Test func decodesGreptileScoreFromComments() throws {
    let json = """
      [
        { "user": { "login": "linear-code[bot]" }, "body": "linked CEN-1" },
        { "user": { "login": "greptile-apps[bot]" }, "body": "<h3>Confidence Score: 4/5</h3>" }
      ]
      """
    #expect(try decodeGreptileScore(stdout: json) == 4)
  }
}

struct MonitoredPullRequestHealthTests {
  private func pullRequest(
    isDraft: Bool = false,
    ciOutcome: BoardPullRequestChecks.ChecksOutcome,
    greptileScore: Int? = nil
  ) -> MonitoredPullRequest {
    MonitoredPullRequest(
      number: 1,
      title: "T",
      url: "https://github.com/a/b/pull/1",
      author: "jo",
      isDraft: isDraft,
      headRefName: "branch",
      updatedAt: Date(timeIntervalSince1970: 0),
      reviewDecision: nil,
      checks: PullRequestCheckBreakdown(checks: []),
      ciOutcome: ciOutcome,
      greptileScore: greptileScore
    )
  }

  @Test func failingChecksAreRed() {
    #expect(pullRequest(ciOutcome: .completed(allPassed: false), greptileScore: 5).health == .red)
  }

  @Test func lowScoreIsRedEvenWhileChecksPend() {
    #expect(pullRequest(ciOutcome: .pending, greptileScore: 3).health == .red)
  }

  @Test func passingWithPerfectScoreIsGreen() {
    #expect(pullRequest(ciOutcome: .completed(allPassed: true), greptileScore: 5).health == .green)
  }

  @Test func passingWithoutGreptileIsGreen() {
    #expect(pullRequest(ciOutcome: .completed(allPassed: true)).health == .green)
  }

  @Test func pendingChecksArePending() {
    #expect(pullRequest(ciOutcome: .pending).health == .pending)
  }

  @Test func draftWithPassingChecksIsNeutral() {
    #expect(pullRequest(isDraft: true, ciOutcome: .completed(allPassed: true)).health == .neutral)
  }

  @Test func noSignalIsNeutral() {
    #expect(pullRequest(ciOutcome: .unknown).health == .neutral)
  }

  @Test func perfectScoreWithoutChecksIsGreen() {
    #expect(pullRequest(ciOutcome: .unknown, greptileScore: 5).health == .green)
  }
}

// MARK: - Reducer flow

@MainActor
struct PRPulseFeatureTests {
  private static let fixedDate = Date(timeIntervalSince1970: 1_750_000_000)

  private static func samplePR(updatedAt: Date = fixedDate) -> MonitoredPullRequest {
    MonitoredPullRequest(
      number: 7,
      title: "Fix the flux capacitor",
      url: "https://github.com/acme/rocket/pull/7",
      author: "jo",
      isDraft: false,
      headRefName: "fix-flux",
      updatedAt: updatedAt,
      reviewDecision: "",
      checks: PullRequestCheckBreakdown(checks: []),
      ciOutcome: .unknown,
      greptileScore: nil
    )
  }

  @Test(.dependencies) func repositoriesChangedFetchesAndStoresSnapshot() async {
    let pullRequest = Self.samplePR()
    let store = TestStore(initialState: BoardFeature.State()) {
      BoardFeature()
    } withDependencies: {
      $0.date = .constant(Self.fixedDate)
      $0[GitClientDependency.self].remoteInfo = { _ in
        GithubRemoteInfo(host: "github.com", owner: "acme", repo: "rocket")
      }
      $0[PRMonitorClient.self].fetchOpenPullRequests = { _, _ in [pullRequest] }
      $0[PRMonitorClient.self].fetchGreptileScore = { _, _, _ in 4 }
    }
    let target = PRPulseTarget(repositoryID: "repo-1", rootPath: "/tmp/repo-1")

    await store.send(.prPulseRepositoriesChanged(targets: [target])) {
      $0.prPulseTargets = [target]
    }
    await store.receive(\._prPulseFetchStarted) {
      $0.prPulseInFlight = ["repo-1"]
    }
    var scored = pullRequest
    scored.greptileScore = 4
    await store.receive(\._prPulseSnapshotLoaded) {
      $0.prPulseInFlight = []
      $0.prPulseSuccessAt = ["repo-1": Self.fixedDate]
      $0.prPulseSnapshots = [
        "repo-1": RepoPullRequestSnapshot(
          repositoryID: "repo-1",
          slug: "acme/rocket",
          pullRequests: [scored],
          fetchedAt: Self.fixedDate
        ),
      ]
    }
  }

  @Test(.dependencies) func fetchFailureRecordsCooldown() async {
    struct Boom: Error {}
    let store = TestStore(initialState: BoardFeature.State()) {
      BoardFeature()
    } withDependencies: {
      $0.date = .constant(Self.fixedDate)
      $0[GitClientDependency.self].remoteInfo = { _ in
        GithubRemoteInfo(host: "github.com", owner: "acme", repo: "rocket")
      }
      $0[PRMonitorClient.self].fetchOpenPullRequests = { _, _ in throw Boom() }
    }
    let target = PRPulseTarget(repositoryID: "repo-1", rootPath: "/tmp/repo-1")

    await store.send(.prPulseRepositoriesChanged(targets: [target])) {
      $0.prPulseTargets = [target]
    }
    await store.receive(\._prPulseFetchStarted) {
      $0.prPulseInFlight = ["repo-1"]
    }
    await store.receive(\._prPulseFetchFailed) {
      $0.prPulseInFlight = []
      $0.prPulseFailureAt = ["repo-1": Self.fixedDate]
    }
  }

  @Test(.dependencies) func repoWithoutGithubRemoteYieldsEmptySnapshot() async {
    let store = TestStore(initialState: BoardFeature.State()) {
      BoardFeature()
    } withDependencies: {
      $0.date = .constant(Self.fixedDate)
      $0[GitClientDependency.self].remoteInfo = { _ in nil }
    }
    let target = PRPulseTarget(repositoryID: "repo-1", rootPath: "/tmp/repo-1")

    await store.send(.prPulseRepositoriesChanged(targets: [target])) {
      $0.prPulseTargets = [target]
    }
    await store.receive(\._prPulseFetchStarted) {
      $0.prPulseInFlight = ["repo-1"]
    }
    await store.receive(\._prPulseSnapshotLoaded) {
      $0.prPulseInFlight = []
      $0.prPulseSuccessAt = ["repo-1": Self.fixedDate]
      $0.prPulseSnapshots = [
        "repo-1": RepoPullRequestSnapshot(
          repositoryID: "repo-1",
          slug: "",
          pullRequests: [],
          fetchedAt: Self.fixedDate
        ),
      ]
    }
  }

  @Test(.dependencies) func tickSkipsInFlightAndFreshTargets() async {
    var state = BoardFeature.State()
    let busy = PRPulseTarget(repositoryID: "busy", rootPath: "/tmp/busy")
    let fresh = PRPulseTarget(repositoryID: "fresh", rootPath: "/tmp/fresh")
    state.prPulseTargets = [busy, fresh]
    state.prPulseInFlight = ["busy"]
    state.prPulseSuccessAt = ["fresh": Self.fixedDate]
    let store = TestStore(initialState: state) {
      BoardFeature()
    } withDependencies: {
      $0.date = .constant(Self.fixedDate)
    }

    // Both targets are ineligible (one in flight, one fresh) → no effects.
    await store.send(._runPRPulseTick)
  }

  @Test(.dependencies) func removingRepositoryDropsItsSnapshot() async {
    var state = BoardFeature.State()
    let keep = PRPulseTarget(repositoryID: "keep", rootPath: "/tmp/keep")
    let drop = PRPulseTarget(repositoryID: "drop", rootPath: "/tmp/drop")
    state.prPulseTargets = [keep, drop]
    state.prPulseSuccessAt = [
      "keep": Self.fixedDate,
      "drop": Self.fixedDate,
    ]
    state.prPulseSnapshots = [
      "keep": RepoPullRequestSnapshot(
        repositoryID: "keep", slug: "a/k", pullRequests: [], fetchedAt: Self.fixedDate
      ),
      "drop": RepoPullRequestSnapshot(
        repositoryID: "drop", slug: "a/d", pullRequests: [], fetchedAt: Self.fixedDate
      ),
    ]
    let store = TestStore(initialState: state) {
      BoardFeature()
    } withDependencies: {
      $0.date = .constant(Self.fixedDate)
    }

    // "keep" is already known and fresh, "drop" disappears → no fetch.
    await store.send(.prPulseRepositoriesChanged(targets: [keep])) {
      $0.prPulseTargets = [keep]
      $0.prPulseSnapshots = [
        "keep": RepoPullRequestSnapshot(
          repositoryID: "keep", slug: "a/k", pullRequests: [], fetchedAt: Self.fixedDate
        ),
      ]
      $0.prPulseSuccessAt = ["keep": Self.fixedDate]
    }
  }
}
