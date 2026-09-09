import Foundation
import Testing

@testable import Supacool

struct PRHealthBarTests {
  private func snapshot(
    state: PRState = .open,
    checks: [GithubPullRequestStatusCheck] = [],
    reviewDecision: String? = nil,
    mergeable: String? = "MERGEABLE",
    mergeStateStatus: String? = nil,
    greptileScore: Int? = nil
  ) -> PullRequestSnapshot {
    var snapshot = PullRequestSnapshot(
      state: state,
      title: "PR",
      statusChecks: checks,
      reviewDecision: reviewDecision,
      mergeable: mergeable,
      mergeStateStatus: mergeStateStatus
    )
    snapshot.greptileScore = greptileScore
    return snapshot
  }

  private static let passing = [
    GithubPullRequestStatusCheck(name: "CI", status: "COMPLETED", conclusion: "SUCCESS")
  ]
  private static let failing = [
    GithubPullRequestStatusCheck(name: "CI", status: "COMPLETED", conclusion: "FAILURE")
  ]
  private static let running = [GithubPullRequestStatusCheck(name: "CI", status: "IN_PROGRESS")]

  private func pr(_ number: Int, state: PRState?) -> SessionReference {
    .pullRequest(owner: "foo", repo: "bar", number: number, state: state, title: nil)
  }

  private func level(_ snapshot: PullRequestSnapshot) -> PRHealthBar.Level {
    PRHealthBar.level(for: snapshot, greptileThreshold: 5)
  }

  // MARK: level classification

  @Test func greenChecksAndFullScoreAreHealthy() {
    #expect(level(snapshot(checks: Self.passing, greptileScore: 5)) == .healthy)
  }

  @Test func failedChecksAreFailing() {
    #expect(level(snapshot(checks: Self.failing)) == .failing)
  }

  @Test func mergeConflictIsFailingEvenWithGreenChecks() {
    // The branch can be green and still unmergeable — the strip must not paint
    // that PR the same as one that is ready.
    let conflicted = snapshot(checks: Self.passing, mergeable: "CONFLICTING", greptileScore: 5)
    #expect(level(conflicted) == .failing)
  }

  @Test func lowGreptileScoreIsWarning() {
    #expect(level(snapshot(checks: Self.passing, greptileScore: 3)) == .warning)
  }

  @Test func changesRequestedIsWarning() {
    let reviewed = snapshot(checks: Self.passing, reviewDecision: "CHANGES_REQUESTED", greptileScore: 5)
    #expect(level(reviewed) == .warning)
  }

  @Test func failedChecksOutrankALowScore() {
    #expect(level(snapshot(checks: Self.failing, greptileScore: 3)) == .failing)
  }

  @Test func runningChecksAreRunningNotIdle() {
    // Orange, like the clock glyph — distinct from a PR nothing has reported
    // on at all.
    #expect(level(snapshot(checks: Self.running)) == .running)
  }

  @Test func noSignalIsPending() {
    #expect(level(snapshot()) == .pending)
  }

  @Test func cleanDraftIsPendingNotHealthy() {
    // A green draft is not a green light — GitHub won't merge it.
    #expect(level(snapshot(state: .draft, checks: Self.passing, greptileScore: 5)) == .pending)
  }

  @Test func brokenDraftStillReadsBroken() {
    #expect(level(snapshot(state: .draft, checks: Self.failing)) == .failing)
  }

  // MARK: strip assembly

  @Test func mergedAndClosedPullRequestsGetNoBar() {
    let references = [pr(1, state: .open), pr(2, state: .merged), pr(3, state: .closed)]
    let snapshots = [
      references[0].dedupeKey: snapshot(checks: Self.passing, greptileScore: 5),
      references[1].dedupeKey: snapshot(state: .merged, checks: Self.passing),
      references[2].dedupeKey: snapshot(state: .closed, checks: Self.failing),
    ]

    let bars = snapshots.healthBars(of: references)

    #expect(bars.map(\.number) == [1])
  }

  @Test func barsSortWorstFirst() {
    let references = (1...4).map { pr($0, state: .open) }
    let snapshots = [
      references[0].dedupeKey: snapshot(checks: Self.passing, greptileScore: 5),
      references[1].dedupeKey: snapshot(checks: Self.running),
      references[2].dedupeKey: snapshot(checks: Self.failing),
      references[3].dedupeKey: snapshot(checks: Self.passing, greptileScore: 2),
    ]

    let bars = snapshots.healthBars(of: references)

    #expect(bars.map(\.number) == [3, 4, 2, 1])
    #expect(bars.map(\.level) == [.failing, .warning, .running, .healthy])
  }

  @Test func unfetchedPullRequestStillGetsAPendingBar() {
    // The count of PRs is itself information; a bar that only appears once
    // `gh` answers would make the strip's width jitter as data lands.
    let references = [pr(7, state: .open)]

    let bars = [String: PullRequestSnapshot]().healthBars(of: references)

    #expect(bars.map(\.level) == [.pending])
    #expect(bars.first?.summary == "#7 — no status yet")
  }

  @Test func conflictIsMarkedForTheBrokenBarShape() {
    let references = [pr(1, state: .open), pr(2, state: .open)]
    let snapshots = [
      references[0].dedupeKey: snapshot(checks: Self.failing),
      references[1].dedupeKey: snapshot(checks: Self.failing, mergeStateStatus: "DIRTY"),
    ]

    let bars = snapshots.healthBars(of: references)

    // Both are red; only the conflicting one is drawn broken.
    #expect(bars.map(\.level) == [.failing, .failing])
    #expect(bars.map(\.isConflicted) == [false, true])
  }

  @Test func summaryNamesTheReasonBehindTheColor() {
    #expect(
      PRHealthBar.summary(number: 5291, snapshot: snapshot(checks: Self.failing))
        == "#5291 — 1 check failed"
    )
    #expect(
      PRHealthBar.summary(
        number: 5291,
        snapshot: snapshot(checks: Self.passing, greptileScore: 3)
      ) == "#5291 — Greptile 3/5"
    )
    #expect(
      PRHealthBar.summary(number: 5291, snapshot: snapshot(checks: Self.running))
        == "#5291 — 1 check running"
    )
    #expect(
      PRHealthBar.summary(
        number: 5291,
        snapshot: snapshot(state: .draft, checks: Self.passing, greptileScore: 5)
      ) == "#5291 — draft"
    )
  }
}

/// A PR URL carrying the clone-URL `.git` suffix used to become a second,
/// unresolvable reference to the same PR — one chip showing `#5481 +1` with
/// two bars, the twin stuck on "Loading…".
struct SessionReferenceRepoNormalizationTests {
  @Test func gitSuffixIsStrippedFromRepositoryName() {
    #expect(SessionReference.normalizedRepositoryName("centrum_backend.git") == "centrum_backend")
    #expect(SessionReference.normalizedRepositoryName("centrum_backend") == "centrum_backend")
    // Only the suffix goes; a dot inside the name is legitimate.
    #expect(SessionReference.normalizedRepositoryName("docs.github.io") == "docs.github.io")
  }

  @Test func bothURLFormsScanToOneReference() {
    let text = """
      pushed to https://github.com/centrumai/centrum_backend.git/pull/5481
      see https://github.com/centrumai/centrum_backend/pull/5481
      """

    let refs = SessionReferenceScannerLive.scanText(text)

    #expect(refs.count == 1)
    #expect(refs.first?.dedupeKey == "pr:centrumai/centrum_backend#5481")
  }

  @Test func storedGitSuffixReferenceCollapsesOnDecode() throws {
    let stored: [SessionReference] = [
      .pullRequest(owner: "centrumai", repo: "centrum_backend", number: 5481, state: .open, title: "Reload"),
      .pullRequest(owner: "centrumai", repo: "centrum_backend.git", number: 5481, state: nil, title: nil),
    ]
    let data = try JSONEncoder().encode(stored)

    let decoded = try JSONDecoder().decode([SessionReference].self, from: data).deduplicatedByKey()

    #expect(decoded.count == 1)
    // The resolved copy wins — the `.git` twin never had a state to lose.
    #expect(
      decoded.first
        == .pullRequest(
          owner: "centrumai", repo: "centrum_backend", number: 5481, state: .open, title: "Reload"
        )
    )
  }
}
