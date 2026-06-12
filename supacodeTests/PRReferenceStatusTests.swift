import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import Supacool

// MARK: - gh pr view decoding

struct PullRequestSnapshotDecodingTests {
  @Test func decodesChecksAndUpdatedAt() throws {
    let stdout = """
      {
        "state": "OPEN",
        "isDraft": false,
        "title": "Add widgets",
        "updatedAt": "2026-06-12T07:00:00Z",
        "statusCheckRollup": [
          {"name": "Unit Tests", "status": "COMPLETED", "conclusion": "SUCCESS"},
          {"name": "Lint", "status": "COMPLETED", "conclusion": "FAILURE"},
          {"context": "ci/legacy", "state": "PENDING", "targetUrl": "https://ci.example/run/1"}
        ]
      }
      """
    let snapshot = try decodePullRequestSnapshot(stdout: stdout)
    #expect(snapshot.state == .open)
    #expect(snapshot.title == "Add widgets")
    #expect(snapshot.updatedAt == Date(timeIntervalSince1970: 1_781_247_600))
    #expect(snapshot.statusChecks.count == 3)
    #expect(snapshot.statusChecks.map(\.checkState) == [.success, .failure, .inProgress])
    #expect(snapshot.greptileScore == nil)
  }

  @Test func decodesWithoutChecksOrTimestamp() throws {
    let stdout = #"{"state": "MERGED", "isDraft": false, "title": "Done"}"#
    let snapshot = try decodePullRequestSnapshot(stdout: stdout)
    #expect(snapshot.state == .merged)
    #expect(snapshot.statusChecks.isEmpty)
    #expect(snapshot.updatedAt == nil)
  }
}

// MARK: - Greptile score reuse policy

struct GreptileScoreReusePolicyTests {
  private static let updatedAt = Date(timeIntervalSince1970: 1_000)

  @Test func reusesWhenUpdatedAtUnchanged() {
    let previous = PullRequestSnapshot(
      state: .open, title: "x", updatedAt: Self.updatedAt, greptileScore: 4
    )
    #expect(BoardFeature.canReuseGreptileScore(previous: previous, updatedAt: Self.updatedAt))
  }

  @Test func refetchesWhenUpdatedAtMoved() {
    let previous = PullRequestSnapshot(
      state: .open, title: "x", updatedAt: Self.updatedAt, greptileScore: 4
    )
    #expect(
      !BoardFeature.canReuseGreptileScore(
        previous: previous, updatedAt: Self.updatedAt.addingTimeInterval(60)
      )
    )
  }

  @Test func refetchesOnFirstFetchOrMissingTimestamps() {
    let previous = PullRequestSnapshot(state: .open, title: "x", updatedAt: Self.updatedAt)
    #expect(!BoardFeature.canReuseGreptileScore(previous: nil, updatedAt: Self.updatedAt))
    #expect(!BoardFeature.canReuseGreptileScore(previous: previous, updatedAt: nil))
    let previousWithoutTimestamp = PullRequestSnapshot(state: .open, title: "x")
    #expect(
      !BoardFeature.canReuseGreptileScore(
        previous: previousWithoutTimestamp, updatedAt: Self.updatedAt
      )
    )
  }
}

// MARK: - Refresh tick populates reference snapshots

@MainActor
struct PRReferenceStatusReducerTests {
  @Test(.dependencies) func prRefreshTickStoresChecksAndGreptileScore() async {
    let ref = SessionReference.pullRequest(
      owner: "acme", repo: "widgets", number: 42, state: nil, title: nil
    )
    var session = Self.sampleSession()
    session.references = [ref]
    session.referencesScannedAt = Date()
    let state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }
    let updatedAt = Date(timeIntervalSince1970: 2_000)
    let checks = [
      GithubPullRequestStatusCheck(name: "Unit Tests", status: "COMPLETED", conclusion: "FAILURE")
    ]
    let scoreLookups = LockIsolated(0)
    let testClock = TestClock()
    let store = TestStore(initialState: state) {
      BoardFeature()
    } withDependencies: {
      $0.continuousClock = testClock
      $0.date = .constant(Date())
      $0.githubCLI.viewPullRequest = { _, _, _ in
        PullRequestSnapshot(
          state: .open, title: "Add widgets", statusChecks: checks, updatedAt: updatedAt
        )
      }
      $0[PRMonitorClient.self].fetchGreptileScore = { _, _, _ in
        scoreLookups.withValue { $0 += 1 }
        return 4
      }
    }
    store.exhaustivity = .off

    await store.send(._runPRRefreshTick)
    await store.skipReceivedActions()
    await store.finish()

    #expect(scoreLookups.value == 1)
    let snapshot = store.state.prReferenceSnapshots[ref.dedupeKey]
    #expect(snapshot?.statusChecks == checks)
    #expect(snapshot?.updatedAt == updatedAt)
    #expect(snapshot?.greptileScore == 4)
    // State + title still land on the persisted reference itself.
    #expect(
      store.state.sessions.first?.references == [
        .pullRequest(owner: "acme", repo: "widgets", number: 42, state: .open, title: "Add widgets")
      ]
    )
  }

  @Test(.dependencies) func prRefreshTickReusesGreptileScoreWhileUpdatedAtUnchanged() async {
    let ref = SessionReference.pullRequest(
      owner: "acme", repo: "widgets", number: 42, state: .open, title: "Add widgets"
    )
    var session = Self.sampleSession()
    session.references = [ref]
    session.referencesScannedAt = Date()
    let updatedAt = Date(timeIntervalSince1970: 2_000)
    var state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }
    state.prReferenceSnapshots[ref.dedupeKey] = PullRequestSnapshot(
      state: .open, title: "Add widgets", updatedAt: updatedAt, greptileScore: 3
    )
    let scoreLookups = LockIsolated(0)
    let testClock = TestClock()
    let store = TestStore(initialState: state) {
      BoardFeature()
    } withDependencies: {
      $0.continuousClock = testClock
      $0.date = .constant(Date())
      $0.githubCLI.viewPullRequest = { _, _, _ in
        PullRequestSnapshot(state: .open, title: "Add widgets", updatedAt: updatedAt)
      }
      $0[PRMonitorClient.self].fetchGreptileScore = { _, _, _ in
        scoreLookups.withValue { $0 += 1 }
        return 5
      }
    }
    store.exhaustivity = .off

    await store.send(._runPRRefreshTick)
    await store.skipReceivedActions()
    await store.finish()

    #expect(scoreLookups.value == 0)
    #expect(store.state.prReferenceSnapshots[ref.dedupeKey]?.greptileScore == 3)
  }

  @Test(.dependencies) func greptileScoreLookupFailureDoesNotFailTheRefresh() async {
    struct Boom: Error {}
    let ref = SessionReference.pullRequest(
      owner: "acme", repo: "widgets", number: 42, state: nil, title: nil
    )
    var session = Self.sampleSession()
    session.references = [ref]
    session.referencesScannedAt = Date()
    let state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }
    let testClock = TestClock()
    let store = TestStore(initialState: state) {
      BoardFeature()
    } withDependencies: {
      $0.continuousClock = testClock
      $0.date = .constant(Date())
      $0.githubCLI.viewPullRequest = { _, _, _ in
        PullRequestSnapshot(state: .open, title: "Add widgets")
      }
      $0[PRMonitorClient.self].fetchGreptileScore = { _, _, _ in throw Boom() }
    }
    store.exhaustivity = .off

    await store.send(._runPRRefreshTick)
    await store.skipReceivedActions()
    await store.finish()

    let snapshot = store.state.prReferenceSnapshots[ref.dedupeKey]
    #expect(snapshot != nil)
    #expect(snapshot?.greptileScore == nil)
    #expect(
      store.state.sessions.first?.references == [
        .pullRequest(owner: "acme", repo: "widgets", number: 42, state: .open, title: "Add widgets")
      ]
    )
  }

  private static func sampleSession(id: UUID = UUID()) -> AgentSession {
    AgentSession(
      id: id,
      repositoryID: "/tmp/repo",
      worktreeID: "/tmp/repo",
      agent: .claude,
      initialPrompt: "Fix the failing tests"
    )
  }
}

// MARK: - Per-session snapshot slicing for the card views

struct PRReferenceSnapshotSlicingTests {
  @Test func forReferencesKeepsOnlyThisSessionsPullRequests() {
    var session = AgentSession(
      repositoryID: "/tmp/repo",
      worktreeID: "/tmp/repo",
      agent: .claude,
      initialPrompt: "x"
    )
    let mine = SessionReference.pullRequest(
      owner: "acme", repo: "widgets", number: 1, state: .open, title: nil
    )
    session.references = [.ticket(id: "CEN-1"), mine]
    let all: [String: PullRequestSnapshot] = [
      mine.dedupeKey: PullRequestSnapshot(state: .open, title: "Mine", greptileScore: 5),
      "pr:other/repo#9": PullRequestSnapshot(state: .open, title: "Other"),
      "ticket:CEN-1": PullRequestSnapshot(state: .open, title: "Bogus ticket entry"),
    ]
    let subset = all.forReferences(of: session)
    #expect(subset.count == 1)
    #expect(subset[mine.dedupeKey]?.title == "Mine")
  }
}
