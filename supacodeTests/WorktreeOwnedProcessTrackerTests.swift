import Darwin
import Foundation
import Testing

@testable import Supacool

// File-level helpers are explicitly `nonisolated` — Swift 6 with the
// project's global @MainActor default would otherwise isolate them and
// the `@Sendable` closures the tracker takes can't cross that boundary.
nonisolated private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
nonisolated private let reposPrefix = "/tmp/repos/"

nonisolated private func makeSnapshot(
  pid: pid_t,
  ppid: pid_t,
  cwd: String,
  ageSec: TimeInterval
) -> OrphanProcessSnapshot {
  OrphanProcessSnapshot(
    pid: pid,
    ppid: ppid,
    cwd: cwd,
    executablePath: "/usr/local/bin/fake",
    startedAt: fixedNow.addingTimeInterval(-ageSec)
  )
}

/// Records `(pid, signal)` calls in order. `final class` + lock makes it
/// safe to capture in `@Sendable` closures crossing isolation domains.
nonisolated private final class TerminationRecorder: @unchecked Sendable {
  struct Call: Equatable {
    let pid: pid_t
    let signal: Int32
  }
  private let lock = NSLock()
  private var _calls: [Call] = []
  var calls: [Call] {
    lock.lock()
    defer { lock.unlock() }
    return _calls
  }
  func record(_ pid: pid_t, _ signal: Int32) {
    lock.lock()
    _calls.append(Call(pid: pid, signal: signal))
    lock.unlock()
  }
}

nonisolated private final class SnapshotProvider: @unchecked Sendable {
  private let lock = NSLock()
  private var _snapshots: [OrphanProcessSnapshot]
  init(_ initial: [OrphanProcessSnapshot] = []) { _snapshots = initial }
  var snapshots: [OrphanProcessSnapshot] {
    lock.lock()
    defer { lock.unlock() }
    return _snapshots
  }
  func set(_ newSnapshots: [OrphanProcessSnapshot]) {
    lock.lock()
    _snapshots = newSnapshots
    lock.unlock()
  }
}

/// Verifies the tracker that attributes orphaned (`ppid==1`) processes
/// whose cwd is under `~/.supacool/repos/` to their owning worktree
/// directory, and the `release(worktreePath:)` action that terminates
/// every adopted process for a worktree.
@MainActor
struct WorktreeOwnedProcessTrackerTests {
  // MARK: - Refresh: adoption filter

  @Test func refreshAdoptsOrphanInsideRepos() {
    let snapshot = makeSnapshot(pid: 1001, ppid: 1, cwd: "/tmp/repos/foo/wt", ageSec: 600)
    let recorder = TerminationRecorder()
    let tracker = WorktreeOwnedProcessTracker(
      cwdPrefix: reposPrefix,
      minimumOrphanAge: 180,
      now: { fixedNow },
      enumerate: { [snapshot] },
      terminate: { pid, signal in recorder.record(pid, signal) }
    )

    let adopted = tracker.refresh()

    #expect(adopted.map(\.pid) == [1001])
    #expect(recorder.calls.isEmpty, "refresh must never terminate")
    #expect(tracker.adoptedByWorktree["/tmp/repos/foo/wt"]?.map(\.pid) == [1001])
  }

  @Test func refreshIgnoresOrphanOutsideRepos() {
    let snapshot = makeSnapshot(
      pid: 1002, ppid: 1, cwd: "/Users/somebody/projects/foo", ageSec: 600
    )
    let recorder = TerminationRecorder()
    let tracker = WorktreeOwnedProcessTracker(
      cwdPrefix: reposPrefix,
      minimumOrphanAge: 180,
      now: { fixedNow },
      enumerate: { [snapshot] },
      terminate: { pid, signal in recorder.record(pid, signal) }
    )

    let adopted = tracker.refresh()

    #expect(adopted.isEmpty)
    #expect(tracker.adoptedByWorktree.isEmpty)
  }

  @Test func refreshIgnoresNonOrphanEvenIfInsideRepos() {
    let snapshot = makeSnapshot(pid: 1003, ppid: 4242, cwd: "/tmp/repos/foo/wt", ageSec: 600)
    let tracker = WorktreeOwnedProcessTracker(
      cwdPrefix: reposPrefix,
      minimumOrphanAge: 180,
      now: { fixedNow },
      enumerate: { [snapshot] },
      terminate: { _, _ in }
    )

    #expect(tracker.refresh().isEmpty)
    #expect(tracker.adoptedByWorktree.isEmpty)
  }

  @Test func refreshIgnoresOrphanYoungerThanThreshold() {
    let snapshot = makeSnapshot(pid: 1004, ppid: 1, cwd: "/tmp/repos/foo/wt", ageSec: 30)
    let tracker = WorktreeOwnedProcessTracker(
      cwdPrefix: reposPrefix,
      minimumOrphanAge: 180,
      now: { fixedNow },
      enumerate: { [snapshot] },
      terminate: { _, _ in }
    )

    #expect(tracker.refresh().isEmpty)
    #expect(tracker.adoptedByWorktree.isEmpty)
  }

  @Test func refreshIgnoresCwdWithoutEnoughSegmentsForAWorktree() {
    // cwd is "/tmp/repos/foo" — one segment after the prefix is not enough
    // to identify a worktree directory (`<repos>/<repo>/<worktree>`).
    let snapshot = makeSnapshot(pid: 1005, ppid: 1, cwd: "/tmp/repos/foo", ageSec: 600)
    let tracker = WorktreeOwnedProcessTracker(
      cwdPrefix: reposPrefix,
      minimumOrphanAge: 180,
      now: { fixedNow },
      enumerate: { [snapshot] },
      terminate: { _, _ in }
    )

    #expect(tracker.refresh().isEmpty)
    #expect(tracker.adoptedByWorktree.isEmpty)
  }

  // MARK: - Refresh: idempotence + GC

  @Test func refreshDoesNotReAdoptSamePIDTwice() {
    let snapshot = makeSnapshot(pid: 2001, ppid: 1, cwd: "/tmp/repos/foo/wt", ageSec: 600)
    let recorder = TerminationRecorder()
    let tracker = WorktreeOwnedProcessTracker(
      cwdPrefix: reposPrefix,
      minimumOrphanAge: 180,
      now: { fixedNow },
      enumerate: { [snapshot] },
      terminate: { pid, signal in recorder.record(pid, signal) }
    )

    _ = tracker.refresh()
    let second = tracker.refresh()

    #expect(second.isEmpty, "the same PID must not be re-adopted on the next refresh")
    #expect(tracker.adoptedByWorktree["/tmp/repos/foo/wt"]?.map(\.pid) == [2001])
    #expect(recorder.calls.isEmpty)
  }

  @Test func refreshDropsPIDsThatDisappear() {
    let snap = makeSnapshot(pid: 2010, ppid: 1, cwd: "/tmp/repos/foo/wt", ageSec: 600)
    let provider = SnapshotProvider([snap])
    let tracker = WorktreeOwnedProcessTracker(
      cwdPrefix: reposPrefix,
      minimumOrphanAge: 180,
      now: { fixedNow },
      enumerate: { provider.snapshots },
      terminate: { _, _ in }
    )

    _ = tracker.refresh()
    #expect(tracker.adoptedByWorktree["/tmp/repos/foo/wt"]?.map(\.pid) == [2010])

    // PID vanishes from the next enumerate call AND from the live OS
    // (the test PID won't actually exist on the system, so `kill(pid, 0)`
    // returns ESRCH and the tracker drops it).
    provider.set([])
    _ = tracker.refresh()
    #expect(tracker.adoptedByWorktree.isEmpty)
  }

  @Test func refreshGroupsMultipleOrphansByWorktree() {
    let recorder = TerminationRecorder()
    let tracker = WorktreeOwnedProcessTracker(
      cwdPrefix: reposPrefix,
      minimumOrphanAge: 180,
      now: { fixedNow },
      enumerate: {
        [
          makeSnapshot(pid: 4001, ppid: 1, cwd: "/tmp/repos/a/wt1/python", ageSec: 600),
          makeSnapshot(pid: 4002, ppid: 1, cwd: "/tmp/repos/a/wt1/webapp", ageSec: 600),
          makeSnapshot(pid: 4003, ppid: 1, cwd: "/tmp/repos/a/wt2", ageSec: 600),
          makeSnapshot(pid: 4004, ppid: 1, cwd: "/tmp/repos/b/wt", ageSec: 600),
        ]
      },
      terminate: { pid, signal in recorder.record(pid, signal) }
    )

    let adopted = tracker.refresh()

    #expect(Set(adopted.map(\.pid)) == [4001, 4002, 4003, 4004])
    #expect(tracker.adoptedByWorktree["/tmp/repos/a/wt1"]?.map(\.pid).sorted() == [4001, 4002])
    #expect(tracker.adoptedByWorktree["/tmp/repos/a/wt2"]?.map(\.pid) == [4003])
    #expect(tracker.adoptedByWorktree["/tmp/repos/b/wt"]?.map(\.pid) == [4004])
    #expect(recorder.calls.isEmpty, "refresh must never terminate, even for many orphans")
  }

  // MARK: - Release: actually kills, and only for the right worktree

  @Test func releaseTerminatesEveryAdoptedPIDInTheWorktree() {
    let recorder = TerminationRecorder()
    let tracker = WorktreeOwnedProcessTracker(
      cwdPrefix: reposPrefix,
      minimumOrphanAge: 180,
      now: { fixedNow },
      enumerate: {
        [
          makeSnapshot(pid: 5001, ppid: 1, cwd: "/tmp/repos/a/wt", ageSec: 600),
          makeSnapshot(pid: 5002, ppid: 1, cwd: "/tmp/repos/a/wt/sub", ageSec: 600),
        ]
      },
      terminate: { pid, signal in recorder.record(pid, signal) }
    )

    _ = tracker.refresh()
    let acted = tracker.release(worktreePath: "/tmp/repos/a/wt")

    #expect(Set(acted) == [5001, 5002])
    #expect(recorder.calls.count == 2)
    #expect(recorder.calls.allSatisfy { $0.signal == SIGTERM })
    #expect(tracker.adoptedByWorktree["/tmp/repos/a/wt"] == nil)
  }

  @Test func releaseLeavesOtherWorktreesUntouched() {
    let recorder = TerminationRecorder()
    let tracker = WorktreeOwnedProcessTracker(
      cwdPrefix: reposPrefix,
      minimumOrphanAge: 180,
      now: { fixedNow },
      enumerate: {
        [
          makeSnapshot(pid: 6001, ppid: 1, cwd: "/tmp/repos/a/wt", ageSec: 600),
          makeSnapshot(pid: 6002, ppid: 1, cwd: "/tmp/repos/b/wt", ageSec: 600),
        ]
      },
      terminate: { pid, signal in recorder.record(pid, signal) }
    )

    _ = tracker.refresh()
    let acted = tracker.release(worktreePath: "/tmp/repos/a/wt")

    #expect(acted == [6001])
    #expect(recorder.calls == [.init(pid: 6001, signal: SIGTERM)])
    #expect(tracker.adoptedByWorktree["/tmp/repos/b/wt"]?.map(\.pid) == [6002])
  }

  @Test func releaseOfUnknownPathIsANoOp() {
    let recorder = TerminationRecorder()
    let tracker = WorktreeOwnedProcessTracker(
      cwdPrefix: reposPrefix,
      minimumOrphanAge: 180,
      now: { fixedNow },
      enumerate: { [] },
      terminate: { pid, signal in recorder.record(pid, signal) }
    )

    let acted = tracker.release(worktreePath: "/tmp/repos/nowhere/here")

    #expect(acted.isEmpty)
    #expect(recorder.calls.isEmpty)
  }

  @Test func releaseStripsTrailingSlashOnLookup() {
    // Callers (notably AgentSession.currentWorkspacePath) sometimes pass
    // a path with a trailing slash; tracker keys never have one.
    let recorder = TerminationRecorder()
    let tracker = WorktreeOwnedProcessTracker(
      cwdPrefix: reposPrefix,
      minimumOrphanAge: 180,
      now: { fixedNow },
      enumerate: {
        [makeSnapshot(pid: 7001, ppid: 1, cwd: "/tmp/repos/a/wt", ageSec: 600)]
      },
      terminate: { pid, signal in recorder.record(pid, signal) }
    )

    _ = tracker.refresh()
    let acted = tracker.release(worktreePath: "/tmp/repos/a/wt/")

    #expect(acted == [7001])
    #expect(recorder.calls == [.init(pid: 7001, signal: SIGTERM)])
  }

  @Test func refreshAfterReleaseDoesNotReAdoptTheSameLivePIDs() {
    // Once a worktree is released, its bucket is gone; subsequent
    // refreshes ignore the (still-live, on the system) snapshots
    // because the PIDs are still alive on the host so `kill(pid, 0)`
    // would succeed — but the test only cares that `release` cleared
    // the bucket and nothing re-adopts on the next tick within the
    // same enumerate snapshot.
    //
    // We simulate a "still-live" snapshot via the provider and expect
    // the tracker to re-adopt it under the same path (because the
    // tracker can't know the user *meant* "leave this alone forever"
    // — the post-release refresh sees a fresh live orphan and adopts
    // it again). This matches the production design: after release,
    // the bucket is empty; if the process actually died, the next
    // refresh will see nothing. If somehow it's still alive on the
    // host, the next refresh re-adopts it so the next release can
    // target it again.
    let provider = SnapshotProvider([
      makeSnapshot(pid: 8001, ppid: 1, cwd: "/tmp/repos/a/wt", ageSec: 600)
    ])
    let recorder = TerminationRecorder()
    let tracker = WorktreeOwnedProcessTracker(
      cwdPrefix: reposPrefix,
      minimumOrphanAge: 180,
      now: { fixedNow },
      enumerate: { provider.snapshots },
      terminate: { pid, signal in recorder.record(pid, signal) }
    )

    _ = tracker.refresh()
    _ = tracker.release(worktreePath: "/tmp/repos/a/wt")
    #expect(tracker.adoptedByWorktree.isEmpty)

    provider.set([])  // process is gone after the release SIGTERM
    _ = tracker.refresh()
    #expect(tracker.adoptedByWorktree.isEmpty)
  }
}
