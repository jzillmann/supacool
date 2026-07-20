import SwiftUI

/// Compact CI + Greptile indicators for a session's PR references, fed by
/// `BoardFeature.State.prReferenceSnapshots`. Visual vocabulary mirrors the
/// PR Pulse popover (`PRPulseButton`) so a PR reads the same wherever it
/// appears: red "N failed", orange "N running", green/secondary otherwise,
/// and a green/red "N/5" capsule for the Greptile confidence score.

/// One-glyph CI summary for the inline reference chip. Hidden while no
/// checks are known — the chip already shows the PR state icon.
struct PRChecksGlyph: View {
  let checks: [GithubPullRequestStatusCheck]

  var body: some View {
    switch BoardPullRequestChecks.outcome(checks: checks) {
    case .unknown:
      EmptyView()
    case .pending:
      Image(systemName: "clock.fill")
        .font(.caption2)
        .foregroundStyle(.orange)
        .accessibilityLabel("Checks running")
    case .completed(let allPassed):
      Image(systemName: allPassed ? "checkmark.circle.fill" : "xmark.circle.fill")
        .font(.caption2)
        .foregroundStyle(allPassed ? .green : .red)
        .accessibilityLabel(allPassed ? "Checks passed" : "Checks failed")
    }
  }
}

/// One-glyph merge-conflict marker for the inline reference chip. Hidden
/// unless GitHub reports the PR can't merge cleanly. Uses the same
/// `arrow.triangle.branch` icon as `PRBallState.mergeConflict` so a conflict
/// reads identically wherever it appears. Sits beside `PRChecksGlyph` — a
/// PR can fail CI *and* conflict, and both are worth seeing at a glance.
struct PRConflictGlyph: View {
  let snapshot: PullRequestSnapshot

  var body: some View {
    if snapshot.hasMergeConflict {
      Image(systemName: "arrow.triangle.branch")
        .font(.caption2)
        .foregroundStyle(.red)
        .accessibilityLabel("Merge conflict")
    }
  }
}

/// Worded CI summary for popover rows: the failing/running count when
/// something needs attention, otherwise the total. Hidden without checks.
struct PRChecksSummaryText: View {
  let checks: [GithubPullRequestStatusCheck]

  var body: some View {
    let breakdown = PullRequestCheckBreakdown(checks: checks)
    if breakdown.failed > 0 {
      Text("\(breakdown.failed) failed")
        .font(.caption2)
        .foregroundStyle(.red)
    } else if breakdown.inProgress + breakdown.expected > 0 {
      Text("\(breakdown.inProgress + breakdown.expected) running")
        .font(.caption2)
        .foregroundStyle(.orange)
    } else if breakdown.total > 0 {
      Text("\(breakdown.total) passed")
        .font(.caption2)
        .foregroundStyle(.green)
    }
  }
}

/// Greptile confidence score capsule ("N/5"). Green at 5/5, red below —
/// same thresholds as the PR Pulse rows. Renders nothing without a score
/// (bot not installed, or review still running) so non-Greptile repos
/// don't grow a dash on every row.
struct GreptileScoreBadge: View {
  let score: Int?

  var body: some View {
    if let score {
      Text("\(score)/5")
        .font(.caption2)
        .monospacedDigit()
        .foregroundStyle(score >= 5 ? Color.green : Color.red)
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(
          (score >= 5 ? Color.green : Color.red).opacity(0.15),
          in: Capsule()
        )
        .help("Greptile confidence score")
    }
  }
}

extension [String: PullRequestSnapshot] {
  /// The subset keyed by `session`'s PR-reference dedupe keys. Cards take
  /// this slice instead of the whole board map so an unrelated PR update
  /// doesn't re-render every card.
  nonisolated func forReferences(of session: AgentSession) -> [String: PullRequestSnapshot] {
    var subset: [String: PullRequestSnapshot] = [:]
    for reference in session.references {
      guard case .pullRequest = reference else { continue }
      if let snapshot = self[reference.dedupeKey] {
        subset[reference.dedupeKey] = snapshot
      }
    }
    return subset
  }

  /// The per-session subset (see `forReferences(of:)`) backfilled from PR
  /// Pulse snapshots for any referenced PR the per-`gh pr view` pipeline
  /// hasn't fetched yet. The reference pipeline is gated by cooldowns,
  /// failure-caching, and an in-flight cap, so a PR can show on the PR Pulse
  /// popover (richer `gh pr list` data) while its reference chip stays blank.
  /// This guarantees a chip shows its CI glyph + Greptile score the moment
  /// *either* pipeline has the data; the per-PR snapshot still wins when both
  /// do, since it's fetched specifically for that PR.
  nonisolated func forReferences(
    of session: AgentSession,
    pulseFallback: [String: RepoPullRequestSnapshot]
  ) -> [String: PullRequestSnapshot] {
    var subset = forReferences(of: session)
    guard !pulseFallback.isEmpty else { return subset }
    let pulseByKey = Self.referenceSnapshots(fromPulse: pulseFallback)
    for reference in session.references {
      guard case .pullRequest = reference, subset[reference.dedupeKey] == nil else { continue }
      if let snapshot = pulseByKey[reference.dedupeKey] {
        subset[reference.dedupeKey] = snapshot
      }
    }
    return subset
  }

  /// Flatten PR Pulse's per-repo snapshots into a `dedupeKey`-keyed map of
  /// reference snapshots, matching `SessionReference.dedupeKey`'s scheme.
  private nonisolated static func referenceSnapshots(
    fromPulse pulse: [String: RepoPullRequestSnapshot]
  ) -> [String: PullRequestSnapshot] {
    var map: [String: PullRequestSnapshot] = [:]
    for repo in pulse.values {
      for pullRequest in repo.pullRequests {
        guard let key = PRPulseReference.dedupeKey(slug: repo.slug, number: pullRequest.number)
        else { continue }
        map[key] = pullRequest.referenceSnapshot
      }
    }
    return map
  }
}

extension PullRequestSnapshot {
  /// Tooltip fragment describing checks + score, e.g.
  /// `" · 2 checks failed · Greptile 4/5"`. Empty when nothing is known.
  var statusHelpSuffix: String {
    var parts: [String] = []
    switch BoardPullRequestChecks.outcome(checks: statusChecks) {
    case .unknown:
      break
    case .pending:
      let breakdown = PullRequestCheckBreakdown(checks: statusChecks)
      parts.append("\(breakdown.inProgress + breakdown.expected) checks running")
    case .completed(let allPassed):
      let breakdown = PullRequestCheckBreakdown(checks: statusChecks)
      parts.append(allPassed ? "checks passed" : "\(breakdown.failed) checks failed")
    }
    if hasMergeConflict {
      parts.append("merge conflict")
    }
    if let greptileScore {
      parts.append("Greptile \(greptileScore)/5")
    }
    return parts.map { " · \($0)" }.joined()
  }
}
