import Foundation

/// "Whose court is the ball in?" for a session-backed pull request.
///
/// The board hides sessions the user can't act on (agent working, or a PR
/// mid-CI / awaiting a reviewer) and surfaces the rest. `PRBallState` turns a
/// `PullRequestSnapshot` into that decision *plus* a human-readable reason, so
/// the "Waiting on Me" pool self-triages: each card says its own next action
/// instead of the user opening every PR to find the one that needs them.
///
/// Precedence is deliberate (first match wins): a settled-but-broken PR
/// (CI failed → conflicts → changes requested) outranks "awaiting review",
/// which outranks the quieter "score low" / "ready to merge" signals.
nonisolated enum PRBallState: Equatable, Sendable {
  // Their court — something outside the user owns the next move. Hide.
  /// At least one check is still running/expected.
  case ciRunning
  /// Checks green, no conflicts, but reviewers haven't decided yet.
  case awaitingReview

  // The user's court — surface with a reason chip.
  /// One or more checks reached a failing terminal state.
  case ciFailed(Int)
  /// `mergeable == CONFLICTING` or `mergeStateStatus == DIRTY`.
  case mergeConflict
  /// A reviewer requested changes.
  case changesRequested
  /// Open WIP draft with an idle agent — the user decides what's next.
  case draft
  /// Mergeable and reviewed, but the Greptile confidence score is below
  /// threshold — worth a look before merging.
  case greptileLow(Int)
  /// Green, mergeable, reviewed (or no review required): the user can merge.
  case readyToMerge
  /// PR was closed without merging.
  case closedUnmerged

  // Done — no action needed.
  case merged

  nonisolated enum Court: Equatable, Sendable {
    case mine
    case theirs
    case done
  }

  /// Severity hint for the reason chip. The view maps this to a color so the
  /// Domain stays free of SwiftUI.
  nonisolated enum Severity: Equatable, Sendable {
    /// Something is wrong / needs fixing (red).
    case attention
    /// Neutral, informational (secondary).
    case info
    /// Good news, a green light to act (green).
    case positive
  }

  var court: Court {
    switch self {
    case .ciRunning, .awaitingReview:
      return .theirs
    case .merged:
      return .done
    case .ciFailed, .mergeConflict, .changesRequested, .draft, .greptileLow, .readyToMerge,
      .closedUnmerged:
      return .mine
    }
  }

  /// Short chip label for mine-court states; `nil` when the board shouldn't
  /// annotate the card (their court / done).
  var reasonLabel: String? {
    switch self {
    case .ciFailed(let count):
      return count == 1 ? "CI failed" : "\(count) checks failed"
    case .mergeConflict:
      return "Conflicts"
    case .changesRequested:
      return "Changes requested"
    case .draft:
      return "Draft"
    case .greptileLow(let score):
      return "Score \(score)/5"
    case .readyToMerge:
      return "Ready to merge"
    case .closedUnmerged:
      return "PR closed"
    case .ciRunning, .awaitingReview, .merged:
      return nil
    }
  }

  var severity: Severity {
    switch self {
    case .ciFailed, .mergeConflict, .changesRequested:
      return .attention
    case .greptileLow:
      return .attention
    case .readyToMerge:
      return .positive
    case .draft, .closedUnmerged:
      return .info
    case .ciRunning, .awaitingReview, .merged:
      return .info
    }
  }

  /// Ordering for "which reason wins" when a session has several PRs in the
  /// user's court — lower is more urgent. Their-court / done states sort last
  /// so they're never surfaced as the card's reason chip.
  var triagePriority: Int {
    switch self {
    case .ciFailed: return 0
    case .mergeConflict: return 1
    case .changesRequested: return 2
    case .greptileLow: return 3
    case .closedUnmerged: return 4
    case .readyToMerge: return 5
    case .draft: return 6
    case .ciRunning, .awaitingReview, .merged: return .max
    }
  }

  var systemImage: String {
    switch self {
    case .ciFailed:
      return "xmark.circle.fill"
    case .mergeConflict:
      return "arrow.triangle.branch"
    case .changesRequested:
      return "exclamationmark.bubble.fill"
    case .draft:
      return "pencil.circle.fill"
    case .greptileLow:
      return "gauge.with.dots.needle.bottom.0percent"
    case .readyToMerge:
      return "checkmark.seal.fill"
    case .closedUnmerged:
      return "xmark.circle.fill"
    case .ciRunning:
      return "clock.fill"
    case .awaitingReview:
      return "eye.fill"
    case .merged:
      return "checkmark.circle.fill"
    }
  }
}

extension PRBallState {
  /// Whether a session belongs in "Waiting on External" given its PR
  /// ball-states: at least one PR is in their court (CI running / awaiting
  /// review) and none have bounced back to the user. An empty list means
  /// "no PR signal here" — `false`, so the caller can fall back to another
  /// source.
  nonisolated static func sessionWaitsExternally(_ states: [PRBallState]) -> Bool {
    guard !states.isEmpty else { return false }
    if states.contains(where: { $0.court == .mine }) { return false }
    return states.contains(where: { $0.court == .theirs })
  }

  /// True when a PR just bounced back into the user's court — the trigger for
  /// a one-shot notification on the transition, not on every poll tick. A nil
  /// `previous` (first time this PR is seen, e.g. right after launch) is never
  /// a transition, so a relaunch doesn't notify about every already-actionable
  /// PR. Mine→mine reason changes (e.g. CI failed → changes requested) also
  /// don't re-fire; the user already knows the ball is theirs.
  nonisolated static func didReturnToCourt(from previous: PRBallState?, to current: PRBallState)
    -> Bool
  {
    guard let previous else { return false }
    return previous.court != .mine && current.court == .mine
  }
}

extension [String: PullRequestSnapshot] {
  /// PR ball-states for `session`, one per PR reference that has a cached
  /// snapshot. Drives both the card's reason chip and the board's
  /// external-court decision off the same explicitly-linked source, so the
  /// two never disagree.
  nonisolated func ballStates(of session: AgentSession, greptileThreshold: Int = 5) -> [PRBallState] {
    session.references.compactMap { reference in
      guard case .pullRequest = reference, let snapshot = self[reference.dedupeKey] else {
        return nil
      }
      return PRBallState(snapshot: snapshot, greptileThreshold: greptileThreshold)
    }
  }

  /// The most urgent "ball is in your court" reason across `session`'s PRs, or
  /// `nil` when none need the user.
  nonisolated func actionableReason(for session: AgentSession, greptileThreshold: Int = 5)
    -> PRBallState?
  {
    ballStates(of: session, greptileThreshold: greptileThreshold)
      .filter { $0.court == .mine }
      .min { $0.triagePriority < $1.triagePriority }
  }
}

extension PRBallState {
  /// Classifies a freshly-fetched PR snapshot. `greptileThreshold` matches the
  /// PR Pulse rows (a score below 5/5 reads as "needs a look").
  nonisolated init(snapshot: PullRequestSnapshot, greptileThreshold: Int = 5) {
    switch snapshot.state {
    case .merged:
      self = .merged
      return
    case .closed:
      self = .closedUnmerged
      return
    case .draft:
      self = .draft
      return
    case .open:
      break
    }

    let checks = snapshot.statusChecks
    if BoardPullRequestChecks.isWaiting(checks: checks) {
      self = .ciRunning
      return
    }

    let breakdown = PullRequestCheckBreakdown(checks: checks)
    if breakdown.failed > 0 {
      self = .ciFailed(breakdown.failed)
      return
    }

    let mergeable = snapshot.mergeable?.uppercased()
    let mergeStateStatus = snapshot.mergeStateStatus?.uppercased()
    if mergeable == "CONFLICTING" || mergeStateStatus == "DIRTY" {
      self = .mergeConflict
      return
    }

    switch snapshot.reviewDecision?.uppercased() {
    case "CHANGES_REQUESTED":
      self = .changesRequested
      return
    case "REVIEW_REQUIRED":
      self = .awaitingReview
      return
    default:
      break
    }

    if let score = snapshot.greptileScore, score < greptileThreshold {
      self = .greptileLow(score)
      return
    }

    self = .readyToMerge
  }
}
