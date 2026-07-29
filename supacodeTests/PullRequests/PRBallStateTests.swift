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

  // MARK: auto-resume classification

  @Test func mechanicalReasonsAreAutoResumable() {
    #expect(PRBallState.ciFailed(1).isAutoResumable)
    #expect(PRBallState.mergeConflict.isAutoResumable)
    #expect(PRBallState.greptileLow(2).isAutoResumable)
  }

  @Test func judgmentReasonsAreNotAutoResumable() {
    for ball: PRBallState in [.changesRequested, .readyToMerge, .closedUnmerged, .draft] {
      #expect(!ball.isAutoResumable)
    }
  }

  // MARK: concurrent auto-resumable conditions

  @Test func collectsAllSimultaneousMechanicalConditions() {
    // The classifier is exclusive (ciFailed wins), but the condition
    // collector reports everything wrong at once so auto-resume can hand
    // the agent one combined instruction.
    let snapshot = PullRequestSnapshot(
      state: .open,
      title: "x",
      statusChecks: [
        GithubPullRequestStatusCheck(name: "CI", status: "COMPLETED", conclusion: "FAILURE")
      ],
      greptileScore: 2,
      mergeable: "CONFLICTING"
    )
    let conditions = PRBallState.autoResumableConditions(snapshot: snapshot)
    #expect(conditions == [.ciFailed(1), .mergeConflict, .greptileLow(2)])
  }

  @Test func singleConditionCollectsAlone() {
    let snapshot = PullRequestSnapshot(
      state: .open,
      title: "x",
      statusChecks: [
        GithubPullRequestStatusCheck(name: "CI", status: "COMPLETED", conclusion: "SUCCESS")
      ],
      greptileScore: 3
    )
    #expect(PRBallState.autoResumableConditions(snapshot: snapshot) == [.greptileLow(3)])
  }

  @Test func nonOpenSnapshotsHaveNoConditions() {
    let merged = PullRequestSnapshot(state: .merged, title: "x", greptileScore: 1)
    #expect(PRBallState.autoResumableConditions(snapshot: merged).isEmpty)
  }

  // MARK: redundant-glyph suppression (reason pill vs inline chip)

  private func session(references: [SessionReference]) -> AgentSession {
    AgentSession(
      repositoryID: "/tmp/repo",
      worktreeID: "/tmp/repo",
      agent: .claude,
      initialPrompt: "x",
      displayName: "x",
      references: references
    )
  }

  private static let pr1 = SessionReference.pullRequest(
    owner: "o", repo: "r", number: 1, state: .open, title: nil
  )
  private static let pr2 = SessionReference.pullRequest(
    owner: "o", repo: "r", number: 2, state: .open, title: nil
  )

  @Test func conflictReasonSuppressesTheConflictGlyph() {
    // The pill says "Conflicts" for this PR, so its own branch glyph is the
    // duplicate — mark exactly it, on exactly this PR.
    let snapshots = [Self.pr1.dedupeKey: snapshot(checks: Self.passing, mergeable: "CONFLICTING")]
    let indicator = snapshots.redundantIndicator(for: session(references: [Self.pr1]))
    #expect(indicator == SuppressedPRIndicator(dedupeKey: Self.pr1.dedupeKey, kind: .conflict))
  }

  @Test func ciFailedReasonSuppressesTheChecksGlyph() {
    let snapshots = [Self.pr1.dedupeKey: snapshot(checks: Self.failing)]
    let indicator = snapshots.redundantIndicator(for: session(references: [Self.pr1]))
    #expect(indicator == SuppressedPRIndicator(dedupeKey: Self.pr1.dedupeKey, kind: .checks))
  }

  @Test func lowGreptileKeepsTheScoreBadgeAndDropsThePill() {
    // The score belongs *on* the PR chip: its red "N/5" badge is the same
    // number in the same color, attached to the PR it grades. So the badge
    // stays and the detached "Score 2/5" pill stands down.
    let snapshots = [Self.pr1.dedupeKey: snapshot(checks: Self.passing, greptileScore: 2)]
    let session = session(references: [Self.pr1])
    #expect(snapshots.redundantIndicator(for: session) == nil)
    #expect(snapshots.actionableReason(for: session) == .greptileLow(2))
    #expect(snapshots.standaloneReason(for: session) == nil)
  }

  @Test func glyphReasonsKeepTheirPill() {
    // CI/conflict pills carry words the bare glyph doesn't, so they survive —
    // it's the glyph that yields (see the suppression tests above).
    let failing = [Self.pr1.dedupeKey: snapshot(checks: Self.failing)]
    #expect(failing.standaloneReason(for: session(references: [Self.pr1])) == .ciFailed(1))
    let conflicting = [Self.pr1.dedupeKey: snapshot(checks: Self.passing, mergeable: "CONFLICTING")]
    #expect(conflicting.standaloneReason(for: session(references: [Self.pr1])) == .mergeConflict)
  }

  @Test func glyphlessReasonSuppressesNothing() {
    // "Ready to merge" / "Changes requested" have no per-chip glyph, so there's
    // nothing to duplicate and every glyph stays.
    let ready = [Self.pr1.dedupeKey: snapshot(checks: Self.passing, reviewDecision: "APPROVED", greptileScore: 5)]
    #expect(ready.redundantIndicator(for: session(references: [Self.pr1])) == nil)
    let changes = [Self.pr1.dedupeKey: snapshot(checks: Self.passing, reviewDecision: "CHANGES_REQUESTED")]
    #expect(changes.redundantIndicator(for: session(references: [Self.pr1])) == nil)
  }

  @Test func theirCourtSuppressesNothing() {
    let running = [Self.pr1.dedupeKey: snapshot(checks: Self.running)]
    #expect(running.redundantIndicator(for: session(references: [Self.pr1])) == nil)
  }

  @Test func suppressionTargetsOnlyTheWinningPR() {
    // Two actionable PRs: CI-failed (priority 0) outranks conflict (priority 1),
    // so the pill speaks for pr1. Only pr1's checks glyph is suppressed; pr2's
    // conflict glyph is separate, real information and must survive.
    let snapshots = [
      Self.pr1.dedupeKey: snapshot(checks: Self.failing),
      Self.pr2.dedupeKey: snapshot(checks: Self.passing, mergeable: "CONFLICTING"),
    ]
    let indicator = snapshots.redundantIndicator(for: session(references: [Self.pr1, Self.pr2]))
    #expect(indicator?.kind(for: Self.pr1.dedupeKey) == .checks)
    #expect(indicator?.kind(for: Self.pr2.dedupeKey) == nil)
  }

  @Test func actionableReferenceReportsTheWinningPRKey() {
    let snapshots = [
      Self.pr1.dedupeKey: snapshot(checks: Self.passing, mergeable: "CONFLICTING"),
      Self.pr2.dedupeKey: snapshot(checks: Self.failing),
    ]
    let winner = snapshots.actionableReference(for: session(references: [Self.pr1, Self.pr2]))
    // ciFailed (pr2) outranks mergeConflict (pr1).
    #expect(winner?.dedupeKey == Self.pr2.dedupeKey)
    #expect(winner?.ball == .ciFailed(1))
  }
}

extension PullRequestSnapshot {
  fileprivate func with(greptileScore: Int?) -> PullRequestSnapshot {
    var copy = self
    copy.greptileScore = greptileScore
    return copy
  }
}
