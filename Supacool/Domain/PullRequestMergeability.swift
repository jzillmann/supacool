import Foundation

/// GitHub computes a PR's mergeability lazily. After a push to the PR or to
/// its base branch it reports `mergeable: UNKNOWN` (and `mergeStateStatus:
/// UNKNOWN`) until a background job finishes. Taken at face value, a
/// conflicted PR reads as conflict-free for one fetch: `PRBallState` calls it
/// ready to merge (green), the next fetch calls it conflicted (red), and every
/// flip recolors the terminal (a ghostty reload) and the board card. So an
/// `UNKNOWN` fetch keeps the last known answer.
nonisolated enum PullRequestMergeability {
  /// `next`, or `previous` when `next` is GitHub's "not computed yet" and
  /// `previous` is a real answer.
  static func known(
    next: (mergeable: String?, mergeStateStatus: String?),
    previous: (mergeable: String?, mergeStateStatus: String?)?
  ) -> (mergeable: String?, mergeStateStatus: String?) {
    guard isUnknown(next.mergeable), let previous, !isUnknown(previous.mergeable), previous.mergeable != nil
    else { return next }
    return previous
  }

  private static func isUnknown(_ mergeable: String?) -> Bool {
    mergeable?.uppercased() == "UNKNOWN"
  }
}

extension PullRequestSnapshot {
  /// This snapshot, with the mergeability of `previous` when GitHub has not
  /// computed it yet. See `PullRequestMergeability`.
  nonisolated func keepingKnownMergeability(from previous: PullRequestSnapshot?) -> PullRequestSnapshot {
    let known = PullRequestMergeability.known(
      next: (mergeable, mergeStateStatus),
      previous: previous.map { ($0.mergeable, $0.mergeStateStatus) }
    )
    var snapshot = self
    snapshot.mergeable = known.mergeable
    snapshot.mergeStateStatus = known.mergeStateStatus
    return snapshot
  }
}

extension RepoPullRequestSnapshot {
  /// This snapshot, with each PR's mergeability taken from `previous` when
  /// GitHub has not computed it yet. See `PullRequestMergeability`.
  nonisolated func keepingKnownMergeability(from previous: RepoPullRequestSnapshot?) -> RepoPullRequestSnapshot {
    guard let previous else { return self }
    let previousByNumber = Dictionary(
      previous.pullRequests.map { ($0.number, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    var snapshot = self
    snapshot.pullRequests = pullRequests.map { pullRequest in
      guard let old = previousByNumber[pullRequest.number] else { return pullRequest }
      let known = PullRequestMergeability.known(
        next: (pullRequest.mergeable, pullRequest.mergeStateStatus),
        previous: (old.mergeable, old.mergeStateStatus)
      )
      var updated = pullRequest
      updated.mergeable = known.mergeable
      updated.mergeStateStatus = known.mergeStateStatus
      return updated
    }
    return snapshot
  }
}
