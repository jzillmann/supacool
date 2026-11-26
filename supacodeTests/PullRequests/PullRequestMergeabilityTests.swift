import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import Supacool

/// GitHub reports `mergeable: UNKNOWN` for a while after a push. That fetch
/// keeps the last known mergeability, so a conflicted PR does not flicker
/// green ("Ready to merge") and back to red on every push to its base.
@MainActor
struct PullRequestMergeabilityTests {
  private static func snapshot(_ mergeable: String?, _ mergeStateStatus: String?) -> PullRequestSnapshot {
    PullRequestSnapshot(
      state: .open,
      title: "Fix it",
      statusChecks: [GithubPullRequestStatusCheck(name: "CI", status: "COMPLETED", conclusion: "SUCCESS")],
      mergeable: mergeable,
      mergeStateStatus: mergeStateStatus
    )
  }

  private static func monitored(_ number: Int, _ mergeable: String?, _ mergeStateStatus: String?)
    -> MonitoredPullRequest
  {
    MonitoredPullRequest(
      number: number,
      title: "PR \(number)",
      url: "https://github.com/acme/rocket/pull/\(number)",
      author: "me",
      isDraft: false,
      headRefName: "branch-\(number)",
      updatedAt: .distantPast,
      reviewDecision: nil,
      mergeable: mergeable,
      mergeStateStatus: mergeStateStatus,
      statusChecks: [],
      greptileScore: nil
    )
  }

  @Test func unknownKeepsThePreviousAnswer() {
    let next = Self.snapshot("UNKNOWN", "UNKNOWN").keepingKnownMergeability(from: Self.snapshot("CONFLICTING", "DIRTY"))
    #expect(next.mergeable == "CONFLICTING")
    #expect(next.mergeStateStatus == "DIRTY")
    #expect(PRBallState(snapshot: next) == .mergeConflict)
  }

  @Test func aRealAnswerReplacesThePreviousOne() {
    let next = Self.snapshot("MERGEABLE", "CLEAN").keepingKnownMergeability(from: Self.snapshot("CONFLICTING", "DIRTY"))
    #expect(next.mergeable == "MERGEABLE")
    #expect(PRBallState(snapshot: next) == .readyToMerge)
  }

  @Test func unknownWithoutAPreviousAnswerStaysUnknown() {
    #expect(Self.snapshot("UNKNOWN", "UNKNOWN").keepingKnownMergeability(from: nil).mergeable == "UNKNOWN")
    let afterUnknown = Self.snapshot("UNKNOWN", "UNKNOWN")
      .keepingKnownMergeability(from: Self.snapshot("UNKNOWN", "UNKNOWN"))
    #expect(afterUnknown.mergeable == "UNKNOWN")
  }

  @Test(.dependencies) func fanoutKeepsAConflictThroughAnUnknownFetch() async {
    let ref = SessionReference.pullRequest(owner: "acme", repo: "widgets", number: 42, state: .open, title: "Fix it")
    var state = BoardFeature.State()
    state.prReferenceSnapshots[ref.dedupeKey] = Self.snapshot("CONFLICTING", "DIRTY")
    let store = TestStore(initialState: state) {
      BoardFeature()
    } withDependencies: {
      $0.date = .constant(Date(timeIntervalSince1970: 1_800_000_000))
    }
    store.exhaustivity = .off

    await store.send(._prStateFanout(refKey: ref.dedupeKey, snapshot: Self.snapshot("UNKNOWN", "UNKNOWN")))
    #expect(store.state.prReferenceSnapshots[ref.dedupeKey]?.mergeable == "CONFLICTING")
  }

  @Test(.dependencies) func pulseKeepsAConflictThroughAnUnknownFetch() async {
    var state = BoardFeature.State()
    state.prPulseTargets = [PRPulseTarget(repositoryID: "repo-1", rootPath: "/tmp/repo-1")]
    state.prPulseSnapshots["repo-1"] = RepoPullRequestSnapshot(
      repositoryID: "repo-1",
      slug: "acme/rocket",
      pullRequests: [Self.monitored(7, "CONFLICTING", "DIRTY"), Self.monitored(8, "MERGEABLE", "CLEAN")],
      fetchedAt: .distantPast
    )
    let store = TestStore(initialState: state) {
      BoardFeature()
    } withDependencies: {
      $0.date = .constant(Date(timeIntervalSince1970: 1_800_000_000))
    }
    store.exhaustivity = .off

    let next = RepoPullRequestSnapshot(
      repositoryID: "repo-1",
      slug: "acme/rocket",
      pullRequests: [
        Self.monitored(7, "UNKNOWN", "UNKNOWN"), Self.monitored(8, "CONFLICTING", "DIRTY"),
        Self.monitored(9, "UNKNOWN", "UNKNOWN"),
      ],
      fetchedAt: .distantPast
    )
    await store.send(._prPulseSnapshotLoaded(snapshot: next))
    let mergeable = store.state.prPulseSnapshots["repo-1"]?.pullRequests.map(\.mergeable)
    #expect(mergeable == ["CONFLICTING", "CONFLICTING", "UNKNOWN"])
  }
}
