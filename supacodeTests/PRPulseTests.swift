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
  @Test func liveFetchOpenPullRequestsUnionsAuthorAndAssignee() async throws {
    let probe = PRMonitorShellProbe()
    let shell = ShellClient(
      run: { _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
      runLoginImpl: { _, arguments, _, _ in
        await probe.record(arguments)
        return ShellOutput(stdout: "[]", stderr: "", exitCode: 0)
      }
    )
    let client = PRMonitorClient.live(shell: shell)

    _ = try await client.fetchOpenPullRequests("acme", "rocket")

    // Two round-trips — one per filter — run concurrently, so order isn't
    // guaranteed. Assert both queries were issued with the expected shape.
    let calls = await probe.arguments
    #expect(calls.count == 2)
    let json = "number,title,url,author,isDraft,headRefName,updatedAt,reviewDecision,statusCheckRollup"
    func expectedCall(filter: String) -> [String] {
      [
        "gh", "pr", "list",
        "--repo", "acme/rocket",
        "--state", "open",
        filter, "@me",
        "--limit", "50",
        "--json", json,
      ]
    }
    #expect(calls.contains(expectedCall(filter: "--author")))
    #expect(calls.contains(expectedCall(filter: "--assignee")))
  }

  @Test func mergeByNumberDedupesPreservingAuthoredFirst() {
    func pr(_ number: Int, author: String) -> MonitoredPullRequest {
      MonitoredPullRequest(
        number: number,
        title: "PR \(number)",
        url: "https://github.com/acme/rocket/pull/\(number)",
        author: author,
        isDraft: false,
        headRefName: "branch-\(number)",
        updatedAt: .distantPast,
        reviewDecision: nil,
        statusChecks: [],
        greptileScore: nil
      )
    }
    // #7 appears in both lists; the authored copy wins and shows once.
    let authored = [pr(7, author: "me"), pr(9, author: "me")]
    let assigned = [pr(7, author: "me"), pr(12, author: "someone")]

    let merged = mergeByNumber(authored, assigned)

    #expect(merged.map(\.number) == [7, 9, 12])
  }

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

private actor PRMonitorShellProbe {
  private(set) var arguments: [[String]] = []

  func record(_ arguments: [String]) {
    self.arguments.append(arguments)
  }
}

struct MonitoredPullRequestHealthTests {
  private static let passingCheck = GithubPullRequestStatusCheck(
    name: "build", status: "COMPLETED", conclusion: "SUCCESS"
  )
  private static let failingCheck = GithubPullRequestStatusCheck(
    name: "test", status: "COMPLETED", conclusion: "FAILURE"
  )
  private static let runningCheck = GithubPullRequestStatusCheck(
    name: "deploy", status: "IN_PROGRESS"
  )
  private static let skippedCheck = GithubPullRequestStatusCheck(
    name: "docs", status: "COMPLETED", conclusion: "SKIPPED"
  )

  private func pullRequest(
    isDraft: Bool = false,
    statusChecks: [GithubPullRequestStatusCheck],
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
      statusChecks: statusChecks,
      greptileScore: greptileScore
    )
  }

  @Test func failingChecksAreRed() {
    let sut = pullRequest(statusChecks: [Self.failingCheck, Self.passingCheck], greptileScore: 5)
    #expect(sut.health == .red)
  }

  @Test func lowScoreIsRedEvenWhileChecksPend() {
    #expect(pullRequest(statusChecks: [Self.runningCheck], greptileScore: 3).health == .red)
  }

  @Test func passingWithPerfectScoreIsGreen() {
    #expect(pullRequest(statusChecks: [Self.passingCheck], greptileScore: 5).health == .green)
  }

  @Test func passingWithoutGreptileIsGreen() {
    #expect(pullRequest(statusChecks: [Self.passingCheck]).health == .green)
  }

  @Test func pendingChecksArePending() {
    #expect(pullRequest(statusChecks: [Self.passingCheck, Self.runningCheck]).health == .pending)
  }

  @Test func draftWithPassingChecksIsNeutral() {
    #expect(pullRequest(isDraft: true, statusChecks: [Self.passingCheck]).health == .neutral)
  }

  @Test func noSignalIsNeutral() {
    #expect(pullRequest(statusChecks: []).health == .neutral)
  }

  @Test func perfectScoreWithoutChecksIsGreen() {
    #expect(pullRequest(statusChecks: [], greptileScore: 5).health == .green)
  }

  @Test func displayOrderPutsFailuresFirstThenRunning() {
    let sut = pullRequest(
      statusChecks: [Self.passingCheck, Self.skippedCheck, Self.runningCheck, Self.failingCheck]
    )
    #expect(sut.statusChecksForDisplay.map(\.displayName) == ["test", "deploy", "build", "docs"])
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
      statusChecks: [],
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

  // MARK: - Ignore

  @Test(.dependencies) func ignoreToggleAddsThenRemovesKey() async {
    Self.clearIgnoreStorage()
    let store = TestStore(initialState: BoardFeature.State()) {
      BoardFeature()
    } withDependencies: {
      $0.date = .constant(Self.fixedDate)
    }

    await store.send(.prPulseIgnoreToggled(repositoryID: "repo-1", number: 7)) {
      $0.$prPulseIgnoredPRKeys.withLock { $0 = ["repo-1#7"] }
    }
    await store.send(.prPulseIgnoreToggled(repositoryID: "repo-1", number: 7)) {
      $0.$prPulseIgnoredPRKeys.withLock { $0 = [] }
    }
  }

  @Test(.dependencies) func snapshotLoadPrunesIgnoreKeysForClosedPRs() async {
    Self.clearIgnoreStorage()
    var state = BoardFeature.State()
    let target = PRPulseTarget(repositoryID: "repo-1", rootPath: "/tmp/repo-1")
    state.prPulseTargets = [target]
    state.prPulseInFlight = ["repo-1"]
    // #7 still open, #9 since merged, #3 belongs to another repo.
    state.$prPulseIgnoredPRKeys.withLock { $0 = ["repo-1#7", "repo-1#9", "repo-2#3"] }
    let store = TestStore(initialState: state) {
      BoardFeature()
    } withDependencies: {
      $0.date = .constant(Self.fixedDate)
    }
    let snapshot = RepoPullRequestSnapshot(
      repositoryID: "repo-1",
      slug: "acme/rocket",
      pullRequests: [Self.samplePR()],
      fetchedAt: Self.fixedDate
    )

    await store.send(._prPulseSnapshotLoaded(snapshot: snapshot)) {
      $0.prPulseInFlight = []
      $0.prPulseSuccessAt = ["repo-1": Self.fixedDate]
      $0.prPulseSnapshots = ["repo-1": snapshot]
      // #9 pruned (gone from snapshot); #7 kept (still open); #3 untouched (other repo).
      $0.$prPulseIgnoredPRKeys.withLock { $0 = ["repo-1#7", "repo-2#3"] }
    }
  }

  @Test(.dependencies) func removingRepositoryDropsItsIgnoreKeys() async {
    Self.clearIgnoreStorage()
    var state = BoardFeature.State()
    let keep = PRPulseTarget(repositoryID: "keep", rootPath: "/tmp/keep")
    let drop = PRPulseTarget(repositoryID: "drop", rootPath: "/tmp/drop")
    state.prPulseTargets = [keep, drop]
    state.prPulseSuccessAt = ["keep": Self.fixedDate, "drop": Self.fixedDate]
    state.$prPulseIgnoredPRKeys.withLock { $0 = ["keep#1", "drop#2"] }
    let store = TestStore(initialState: state) {
      BoardFeature()
    } withDependencies: {
      $0.date = .constant(Self.fixedDate)
    }

    await store.send(.prPulseRepositoriesChanged(targets: [keep])) {
      $0.prPulseTargets = [keep]
      $0.prPulseSuccessAt = ["keep": Self.fixedDate]
      $0.$prPulseIgnoredPRKeys.withLock { $0 = ["keep#1"] }
    }
  }

  private static func clearIgnoreStorage() {
    UserDefaults.standard.removeObject(forKey: "prPulseIgnoredPRKeys")
  }
}
