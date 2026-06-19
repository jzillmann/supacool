import Foundation
import Testing

@testable import Supacool

/// Decision matrix for `BoardFeature.pullRequestReturnOutcome` — the pure core
/// of Phase-3 auto-resume (armed reason + idle agent + retry budget) vs. the
/// Phase-2 notification fallback.
struct PRAutoResumeOutcomeTests {
  private let ref = SessionReference.pullRequest(
    owner: "acme", repo: "widgets", number: 42, state: .open, title: "Fix it"
  )
  private var refKey: String { ref.dedupeKey }

  private let running = PullRequestSnapshot(
    state: .open,
    title: "Fix it",
    statusChecks: [GithubPullRequestStatusCheck(name: "CI", status: "IN_PROGRESS")]
  )
  private let failed = PullRequestSnapshot(
    state: .open,
    title: "Fix it",
    statusChecks: [GithubPullRequestStatusCheck(name: "CI", status: "COMPLETED", conclusion: "FAILURE")]
  )

  private func session(busy: Bool) -> AgentSession {
    AgentSession(
      repositoryID: "/tmp/repo",
      worktreeID: "/tmp/repo",
      agent: .claude,
      initialPrompt: "x",
      displayName: "Proper Waiting",
      lastKnownBusy: busy,
      references: [ref]
    )
  }

  private func outcome(
    previous: PullRequestSnapshot?,
    next: PullRequestSnapshot,
    enabled: Bool,
    busy: Bool = false,
    priorAttempts: Int = 0
  ) -> BoardFeature.PRReturnOutcome {
    BoardFeature.pullRequestReturnOutcome(
      refKey: refKey,
      previous: previous,
      next: next,
      sessions: [session(busy: busy)],
      autoResumeEnabled: enabled,
      priorAttempts: priorAttempts,
      maxAttempts: 3
    )
  }

  @Test func armedIdleEnabledAutoResumes() {
    let result = outcome(previous: running, next: failed, enabled: true)
    guard case .autoResume(_, let prompt, _) = result else {
      Issue.record("expected autoResume, got \(result)")
      return
    }
    #expect(prompt.contains("CI failed"))
  }

  @Test func mergeConflictAutoResumesWhenArmedAndIdle() {
    let conflicting = PullRequestSnapshot(
      state: .open,
      title: "Fix it",
      statusChecks: [GithubPullRequestStatusCheck(name: "CI", status: "COMPLETED", conclusion: "SUCCESS")],
      mergeable: "CONFLICTING"
    )
    let result = outcome(previous: running, next: conflicting, enabled: true)
    guard case .autoResume(_, let prompt, _) = result else {
      Issue.record("expected autoResume for merge conflict, got \(result)")
      return
    }
    #expect(prompt.contains("merge conflicts"))
  }

  @Test func busyAgentNeverAutoResumed() {
    // Never interrupt a working agent — fall back to notifying.
    let result = outcome(previous: running, next: failed, enabled: true, busy: true)
    guard case .notify = result else {
      Issue.record("expected notify for busy agent, got \(result)")
      return
    }
  }

  @Test func disabledFlagJustNotifies() {
    let result = outcome(previous: running, next: failed, enabled: false)
    guard case .notify = result else {
      Issue.record("expected notify when disabled, got \(result)")
      return
    }
  }

  @Test func exhaustedBudgetResurfacesWithBreadcrumb() {
    let result = outcome(previous: running, next: failed, enabled: true, priorAttempts: 3)
    guard case .notify(.pullRequestReturnedToCourt(_, let body)) = result else {
      Issue.record("expected notify at cap, got \(result)")
      return
    }
    #expect(body.contains("auto-resumed 3×"))
  }

  @Test func judgmentReasonNotifiesEvenWhenArmed() {
    // changes-requested is your call — never auto-resumed, even with the flag on.
    let changesRequested = PullRequestSnapshot(
      state: .open,
      title: "Fix it",
      statusChecks: [GithubPullRequestStatusCheck(name: "CI", status: "COMPLETED", conclusion: "SUCCESS")],
      reviewDecision: "CHANGES_REQUESTED"
    )
    let result = outcome(previous: running, next: changesRequested, enabled: true)
    guard case .notify = result else {
      Issue.record("expected notify for changes-requested, got \(result)")
      return
    }
  }

  @Test func nonTransitionIsNone() {
    // Already mine last tick → no fresh bounce → nothing.
    guard case .none = outcome(previous: failed, next: failed, enabled: true) else {
      Issue.record("expected none for non-transition")
      return
    }
  }

  @Test func firstSightIsNone() {
    guard case .none = outcome(previous: nil, next: failed, enabled: true) else {
      Issue.record("expected none for first sight")
      return
    }
  }
}
