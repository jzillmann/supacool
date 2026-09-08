import Foundation

/// One bar per *live* pull request on a session.
///
/// The collapsed reference stack chip used to read `#5291 +3 ✓ 5/5`: a number,
/// a count, and the featured PR's status standing in for all four. The three
/// PRs behind the `+3` could be failing, conflicting, or unreviewed and the
/// card said nothing. `PRHealthBar` turns the stack into a strip of marks —
/// one per PR, coloured by that PR's own state — so a card carrying four PRs
/// shows four signals.
///
/// Merged and closed PRs get no bar: their CI and score are settled history
/// (the same rule `PRState.showsLiveStatus` applies to chip glyphs), and the
/// stack popover still lists them in full.
nonisolated struct PRHealthBar: Equatable, Sendable, Identifiable {
  /// Colour tier, ordered worst-first so the strip can sort by it and the
  /// eye lands on the PR that needs the user.
  nonisolated enum Level: Int, Equatable, Sendable, Comparable {
    /// A check reached a failing terminal state, or GitHub can't merge the
    /// branch. Red.
    case failing
    /// Greptile scored below threshold, or a reviewer requested changes.
    /// Yellow — worth a look, nothing is broken.
    case warning
    /// Checks still running, nothing has reported yet, or a draft that is
    /// otherwise clean. Secondary — no signal to act on.
    case pending
    /// Checks green, mergeable, and Greptile (when present) at full score.
    case healthy

    nonisolated static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
  }

  /// `SessionReference.dedupeKey` of the PR this bar stands for.
  let key: String
  let number: Int
  let level: Level
  /// Drawn as a broken bar rather than a solid one. A conflict is a different
  /// *kind* of problem from a red build — it needs a rebase, not a fix — so it
  /// gets a different shape instead of competing for another colour.
  let isConflicted: Bool
  /// One tooltip line, e.g. `#5291 — 2 checks failed`.
  let summary: String

  var id: String { key }

  /// Classifies one snapshot. Precedence mirrors `PRBallState`: broken
  /// (conflict → failed checks) outranks "somebody should look" (changes
  /// requested → low score), which outranks the quiet states.
  nonisolated static func level(
    for snapshot: PullRequestSnapshot,
    greptileThreshold: Int
  ) -> Level {
    if snapshot.hasMergeConflict { return .failing }
    if case .completed(allPassed: false) = snapshot.checksOutcome { return .failing }
    if snapshot.reviewDecision?.uppercased() == "CHANGES_REQUESTED" { return .warning }
    if let score = snapshot.greptileScore, score < greptileThreshold { return .warning }
    // A draft is work in flight whatever CI says — green would invite a merge
    // that GitHub won't allow. Same call `MonitoredPullRequest.health` makes.
    if snapshot.state == .draft { return .pending }
    switch snapshot.checksOutcome {
    case .pending:
      return .pending
    case .completed:
      // allPassed == true; the failing case returned above.
      return .healthy
    case .unknown:
      // Nothing reported. A full-score Greptile review is still a green light;
      // without one there is simply no signal yet.
      return snapshot.greptileScore == nil ? .pending : .healthy
    }
  }

  /// Tooltip fragment for one PR, naming the *reason* behind its colour.
  nonisolated static func summary(number: Int, snapshot: PullRequestSnapshot) -> String {
    let breakdown = PullRequestCheckBreakdown(checks: snapshot.statusChecks)
    var reason: String
    if snapshot.hasMergeConflict {
      reason = "merge conflict"
    } else if case .completed(allPassed: false) = snapshot.checksOutcome {
      reason = breakdown.failed == 1 ? "1 check failed" : "\(breakdown.failed) checks failed"
    } else if snapshot.reviewDecision?.uppercased() == "CHANGES_REQUESTED" {
      reason = "changes requested"
    } else if let score = snapshot.greptileScore, score < 5 {
      reason = "Greptile \(score)/5"
    } else if case .pending = snapshot.checksOutcome {
      let running = breakdown.inProgress + breakdown.expected
      reason =
        switch running {
        case 0: "checks pending"
        case 1: "1 check running"
        default: "\(running) checks running"
        }
    } else if snapshot.state == .draft {
      reason = "draft"
    } else if case .unknown = snapshot.checksOutcome, snapshot.greptileScore == nil {
      reason = "no status yet"
    } else {
      reason = "green"
    }
    if snapshot.state == .draft, reason != "draft" {
      reason = "draft · \(reason)"
    }
    return "#\(number) — \(reason)"
  }
}

extension [String: PullRequestSnapshot] {
  /// One bar per live PR reference on `session`, worst-first then by PR
  /// number. A referenced PR with no snapshot yet still gets a (pending) bar —
  /// the count of PRs is itself information, and a bar that appears only once
  /// `gh` answers would make the strip's width jitter as data lands.
  nonisolated func healthBars(of session: AgentSession, greptileThreshold: Int = 5)
    -> [PRHealthBar]
  {
    healthBars(of: session.references, greptileThreshold: greptileThreshold)
  }

  /// Same, for a view that holds the reference slice rather than the session —
  /// the collapsed stack chip is handed only its own PRs.
  nonisolated func healthBars(of references: [SessionReference], greptileThreshold: Int = 5)
    -> [PRHealthBar]
  {
    references
      .compactMap { reference -> PRHealthBar? in
        guard case .pullRequest(_, _, let number, let state, _) = reference,
          state?.showsLiveStatus ?? true
        else { return nil }
        guard let snapshot = self[reference.dedupeKey] else {
          return PRHealthBar(
            key: reference.dedupeKey,
            number: number,
            level: .pending,
            isConflicted: false,
            summary: "#\(number) — no status yet"
          )
        }
        return PRHealthBar(
          key: reference.dedupeKey,
          number: number,
          level: PRHealthBar.level(for: snapshot, greptileThreshold: greptileThreshold),
          isConflicted: snapshot.hasMergeConflict,
          summary: PRHealthBar.summary(number: number, snapshot: snapshot)
        )
      }
      .sorted { ($0.level, $0.number) < ($1.level, $1.number) }
  }
}
