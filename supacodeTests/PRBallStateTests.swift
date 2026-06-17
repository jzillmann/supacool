import Foundation
import Testing

@testable import Supacool

struct PRBallStateTests {
  private func snapshot(
    state: PRState = .open,
    checks: [GithubPullRequestStatusCheck] = [],
    reviewDecision: String? = nil,
    mergeable: String? = "MERGEABLE",
    mergeStateStatus: String? = nil,
    greptileScore: Int? = nil
  ) -> PullRequestSnapshot {
    PullRequestSnapshot(
      state: state,
      title: "PR",
      statusChecks: checks,
      reviewDecision: reviewDecision,
      mergeable: mergeable,
      mergeStateStatus: mergeStateStatus
    )
    .with(greptileScore: greptileScore)
  }

  private static let passing = [GithubPullRequestStatusCheck(name: "CI", status: "COMPLETED", conclusion: "SUCCESS")]
  private static let failing = [GithubPullRequestStatusCheck(name: "CI", status: "COMPLETED", conclusion: "FAILURE")]
  private static let running = [GithubPullRequestStatusCheck(name: "CI", status: "IN_PROGRESS")]

  // MARK: terminal PR states

  @Test func mergedIsDone() {
    let ball = PRBallState(snapshot: snapshot(state: .merged))
    #expect(ball == .merged)
    #expect(ball.court == .done)
    #expect(ball.reasonLabel == nil)
  }

  @Test func closedUnmergedIsMine() {
    let ball = PRBallState(snapshot: snapshot(state: .closed))
    #expect(ball == .closedUnmerged)
    #expect(ball.court == .mine)
  }

  @Test func draftIsMine() {
    // A WIP draft with an idle agent is the user's call, not external —
    // preserves the pre-classifier bucket behavior (drafts were never
    // "Waiting on External").
    let ball = PRBallState(snapshot: snapshot(state: .draft))
    #expect(ball == .draft)
    #expect(ball.court == .mine)
  }

  // MARK: their court

  @Test func runningChecksAreTheirCourt() {
    let ball = PRBallState(snapshot: snapshot(checks: Self.running))
    #expect(ball == .ciRunning)
    #expect(ball.court == .theirs)
    #expect(ball.reasonLabel == nil)
  }

  @Test func awaitingReviewIsTheirCourt() {
    let ball = PRBallState(
      snapshot: snapshot(checks: Self.passing, reviewDecision: "REVIEW_REQUIRED")
    )
    #expect(ball == .awaitingReview)
    #expect(ball.court == .theirs)
  }

  // MARK: my court

  @Test func failedChecksAreMineWithCount() {
    let ball = PRBallState(snapshot: snapshot(checks: Self.failing))
    #expect(ball == .ciFailed(1))
    #expect(ball.court == .mine)
    #expect(ball.reasonLabel == "CI failed")
  }

  @Test func conflictsViaMergeable() {
    let ball = PRBallState(snapshot: snapshot(checks: Self.passing, mergeable: "CONFLICTING"))
    #expect(ball == .mergeConflict)
  }

  @Test func conflictsViaMergeStateStatusDirty() {
    let ball = PRBallState(
      snapshot: snapshot(checks: Self.passing, mergeable: "UNKNOWN", mergeStateStatus: "DIRTY")
    )
    #expect(ball == .mergeConflict)
  }

  @Test func changesRequestedIsMine() {
    let ball = PRBallState(
      snapshot: snapshot(checks: Self.passing, reviewDecision: "CHANGES_REQUESTED")
    )
    #expect(ball == .changesRequested)
    #expect(ball.court == .mine)
  }

  @Test func lowGreptileScoreIsMine() {
    let ball = PRBallState(
      snapshot: snapshot(checks: Self.passing, reviewDecision: "APPROVED", greptileScore: 2)
    )
    #expect(ball == .greptileLow(2))
    #expect(ball.reasonLabel == "Score 2/5")
  }

  @Test func approvedPassingMergeableIsReadyToMerge() {
    let ball = PRBallState(
      snapshot: snapshot(checks: Self.passing, reviewDecision: "APPROVED", greptileScore: 5)
    )
    #expect(ball == .readyToMerge)
    #expect(ball.court == .mine)
    #expect(ball.severity == .positive)
  }

  @Test func passingNoReviewRequiredIsReadyToMerge() {
    // Personal repos with no required reviewers: green checks → mergeable.
    let ball = PRBallState(snapshot: snapshot(checks: Self.passing, reviewDecision: nil))
    #expect(ball == .readyToMerge)
  }

  // MARK: precedence

  @Test func failedChecksOutrankConflictAndReview() {
    let ball = PRBallState(
      snapshot: snapshot(
        checks: Self.failing,
        reviewDecision: "CHANGES_REQUESTED",
        mergeable: "CONFLICTING"
      )
    )
    #expect(ball == .ciFailed(1))
  }

  @Test func runningChecksOutrankEverything() {
    let ball = PRBallState(
      snapshot: snapshot(
        checks: Self.running,
        reviewDecision: "CHANGES_REQUESTED",
        mergeable: "CONFLICTING",
        greptileScore: 1
      )
    )
    #expect(ball == .ciRunning)
  }

  @Test func conflictOutranksChangesRequested() {
    let ball = PRBallState(
      snapshot: snapshot(
        checks: Self.passing,
        reviewDecision: "CHANGES_REQUESTED",
        mergeable: "CONFLICTING"
      )
    )
    #expect(ball == .mergeConflict)
  }

  @Test func reviewRequiredOutranksLowGreptile() {
    let ball = PRBallState(
      snapshot: snapshot(
        checks: Self.passing,
        reviewDecision: "REVIEW_REQUIRED",
        greptileScore: 1
      )
    )
    #expect(ball == .awaitingReview)
  }

  // MARK: mergeable UNKNOWN must not flap into readyToMerge prematurely... but
  // GitHub leaves checks/review as the real signal. With everything green and
  // mergeable UNKNOWN (still computing), we still treat it as ready — the user
  // can attempt the merge and GitHub will block it if needed.
  @Test func unknownMergeableWithGreenStillReady() {
    let ball = PRBallState(
      snapshot: snapshot(checks: Self.passing, reviewDecision: "APPROVED", mergeable: "UNKNOWN")
    )
    #expect(ball == .readyToMerge)
  }

  // MARK: session-level external aggregation

  @Test func noPRsIsNotExternal() {
    #expect(!PRBallState.sessionWaitsExternally([]))
  }

  @Test func allTheirCourtIsExternal() {
    #expect(PRBallState.sessionWaitsExternally([.ciRunning, .awaitingReview]))
  }

  @Test func anyMineCourtKeepsSessionSurfaced() {
    // A second PR that's back in the user's court must override a sibling
    // that's still mid-CI — the user has something to do.
    #expect(!PRBallState.sessionWaitsExternally([.ciRunning, .ciFailed(1)]))
  }

  @Test func onlyDonePRsIsNotExternal() {
    // Merged PRs neither block externally nor demand action; fall through to
    // the normal idle classification.
    #expect(!PRBallState.sessionWaitsExternally([.merged]))
  }

  // MARK: return-to-court transition (notification trigger)

  @Test func theirCourtToMineIsAReturn() {
    #expect(PRBallState.didReturnToCourt(from: .ciRunning, to: .ciFailed(1)))
    #expect(PRBallState.didReturnToCourt(from: .awaitingReview, to: .readyToMerge))
  }

  @Test func firstSightIsNeverAReturn() {
    // nil previous (e.g. right after launch) must not notify, or every
    // already-actionable PR would fire a banner on startup.
    #expect(!PRBallState.didReturnToCourt(from: nil, to: .ciFailed(1)))
  }

  @Test func mineToMineDoesNotReFire() {
    // Reason change within the user's court isn't a fresh bounce.
    #expect(!PRBallState.didReturnToCourt(from: .ciFailed(1), to: .changesRequested))
  }

  @Test func stayingInTheirCourtIsNotAReturn() {
    #expect(!PRBallState.didReturnToCourt(from: .ciRunning, to: .awaitingReview))
  }
}

extension PullRequestSnapshot {
  fileprivate func with(greptileScore: Int?) -> PullRequestSnapshot {
    var copy = self
    copy.greptileScore = greptileScore
    return copy
  }
}
