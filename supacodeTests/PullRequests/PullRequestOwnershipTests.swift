import Foundation
import Testing

@testable import Supacool

/// `PullRequestOwnership` resolves one owner per PR across board sessions:
/// newest claim > created here > first seen. Everyone else is a watcher.
struct PullRequestOwnershipTests {
  private let pr = SessionReference.pullRequest(
    owner: "acme", repo: "widgets", number: 42, state: .open, title: "Fix it"
  )
  private var key: String { pr.dedupeKey }
  private let base = Date(timeIntervalSince1970: 1_000_000)

  private func session(
    _ name: String,
    createdAt offset: TimeInterval,
    references: [SessionReference]? = nil,
    marks: PullRequestOwnershipMarks = PullRequestOwnershipMarks()
  ) -> AgentSession {
    AgentSession(
      repositoryID: "/tmp/repo",
      worktreeID: "/tmp/repo/\(name)",
      agent: .claude,
      initialPrompt: "x",
      displayName: name,
      createdAt: base.addingTimeInterval(offset),
      references: references ?? [pr],
      pullRequestOwnership: marks
    )
  }

  @Test func firstSeenSessionOwnsWithoutStrongerSignal() {
    let early = session("early", createdAt: 0)
    let late = session("late", createdAt: 100)
    #expect(PullRequestOwnership.ownerID(of: key, in: [late, early]) == early.id)
    #expect(PullRequestOwnership.holders(of: key, in: [late, early]).map(\.id) == [early.id, late.id])
  }

  @Test func firstSeenStampBeatsSessionAge() {
    // The old session only picked the PR up long after the new one opened it.
    let old = session("old", createdAt: 0, marks: .init(firstSeenAt: [key: base.addingTimeInterval(500)]))
    let fresh = session("fresh", createdAt: 100, marks: .init(firstSeenAt: [key: base.addingTimeInterval(110)]))
    #expect(PullRequestOwnership.ownerID(of: key, in: [old, fresh]) == fresh.id)
  }

  @Test func creatorBeatsEarlierMention() {
    let mentioner = session("mentioner", createdAt: 0)
    let creator = session("creator", createdAt: 100, marks: .init(created: [key]))
    #expect(PullRequestOwnership.ownerID(of: key, in: [mentioner, creator]) == creator.id)
  }

  @Test func newestClaimBeatsCreator() {
    let creator = session("creator", createdAt: 0, marks: .init(created: [key]))
    let olderClaim = session("a", createdAt: 10, marks: .init(claimedAt: [key: base.addingTimeInterval(20)]))
    let newerClaim = session("b", createdAt: 20, marks: .init(claimedAt: [key: base.addingTimeInterval(30)]))
    #expect(PullRequestOwnership.ownerID(of: key, in: [creator, olderClaim, newerClaim]) == newerClaim.id)
  }

  @Test func ownerOnlyCountsSessionsThatStillHoldThePR() {
    // A claim survives on a session that later unlinked the PR; it must not win.
    let unlinked = session(
      "unlinked", createdAt: 0, references: [], marks: .init(claimedAt: [key: base])
    )
    let holder = session("holder", createdAt: 10)
    #expect(PullRequestOwnership.ownerID(of: key, in: [unlinked, holder]) == holder.id)
    #expect(PullRequestOwnership.ownerID(of: "pr:acme/widgets#7", in: [holder]) == nil)
  }

  @Test func rolesDescribeOwnerAndWatcher() {
    let owner = session("owner", createdAt: 0, marks: .init(created: [key]))
    let stray = session("stray", createdAt: 10)
    let sessions = [owner, stray]

    let ownerRole = PullRequestOwnership.roles(for: owner, in: sessions)[key]
    #expect(ownerRole == .owner(reason: .created, sharedWith: [.init(id: stray.id, name: "stray")]))
    #expect(ownerRole?.needsAttention == false)

    let strayRole = PullRequestOwnership.roles(for: stray, in: sessions)[key]
    #expect(strayRole == .watcher(owner: .init(id: owner.id, name: "owner"), acknowledged: false, isSettled: false))
    #expect(strayRole?.needsAttention == true)
    #expect(PullRequestOwnership.watchedKeys(of: stray, in: sessions) == [key])
    #expect(PullRequestOwnership.watchedKeys(of: owner, in: sessions).isEmpty)
  }

  @Test func acknowledgedWatcherStopsWarning() {
    let owner = session("owner", createdAt: 0)
    let watcher = session("watcher", createdAt: 10, marks: .init(acknowledgedWatching: [key]))
    let role = PullRequestOwnership.roles(for: watcher, in: [owner, watcher])[key]
    #expect(role?.isWatcher == true)
    #expect(role?.needsAttention == false)
  }

  @Test func settledPullRequestNeverWarns() {
    let merged = SessionReference.pullRequest(
      owner: "acme", repo: "widgets", number: 42, state: .merged, title: "Fix it"
    )
    let owner = session("owner", createdAt: 0, references: [merged])
    let watcher = session("watcher", createdAt: 10, references: [merged])
    let role = PullRequestOwnership.roles(for: watcher, in: [owner, watcher])[key]
    #expect(role?.isWatcher == true)
    #expect(role?.needsAttention == false)
  }

  @Test func unsharedPullRequestHasPlainOwnerRole() {
    let only = session("only", createdAt: 0)
    let role = PullRequestOwnership.roles(for: only, in: [only])[key]
    #expect(role == .owner(reason: .firstSeen, sharedWith: []))
  }

  // MARK: - Ball-state exclusion

  @Test func watchedPullRequestDoesNotDriveTheWatchersTriage() {
    let failing = PullRequestSnapshot(
      state: .open,
      title: "Fix it",
      statusChecks: [GithubPullRequestStatusCheck(name: "CI", status: "COMPLETED", conclusion: "FAILURE")]
    )
    let snapshots = [key: failing]
    let watcher = session("watcher", createdAt: 10)
    #expect(snapshots.actionableReason(for: watcher) == .ciFailed(1))
    #expect(snapshots.actionableReason(for: watcher, excluding: [key]) == nil)
    #expect(snapshots.ballStates(of: watcher, excluding: [key]).isEmpty)
  }

  // MARK: - Persistence

  @Test func marksRoundTripAndDecodeMissingFieldsAsEmpty() throws {
    let marks = PullRequestOwnershipMarks(
      created: [key],
      claimedAt: [key: base],
      firstSeenAt: [key: base],
      acknowledgedWatching: ["pr:acme/widgets#7"]
    )
    let decoded = try JSONDecoder().decode(
      PullRequestOwnershipMarks.self,
      from: JSONEncoder().encode(marks)
    )
    #expect(decoded == marks)
    let empty = try JSONDecoder().decode(PullRequestOwnershipMarks.self, from: Data("{}".utf8))
    #expect(empty == PullRequestOwnershipMarks())
  }

  @Test func legacySessionWithoutMarksIsQueuedForRescan() throws {
    var legacy = session("legacy", createdAt: 0)
    legacy.referencesScannedAt = base
    var json = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any]
    )
    json.removeValue(forKey: "pullRequestOwnership")
    let decoded = try JSONDecoder().decode(
      AgentSession.self,
      from: JSONSerialization.data(withJSONObject: json)
    )
    #expect(decoded.pullRequestOwnership == PullRequestOwnershipMarks())
    // Nil forces the next card appearance to rescan and detect `gh pr create`.
    #expect(decoded.referencesScannedAt == nil)

    let current = try JSONDecoder().decode(AgentSession.self, from: JSONEncoder().encode(legacy))
    #expect(current.referencesScannedAt != nil)
  }
}
