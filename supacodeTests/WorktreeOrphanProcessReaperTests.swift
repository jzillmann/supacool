import Darwin
import Foundation
import Testing

@testable import Supacool

// File-level helpers are explicitly `nonisolated` — Swift 6 with the
// project's global @MainActor default would otherwise isolate them and
// the `@Sendable` closures the reaper takes can't cross that boundary.
nonisolated private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

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

/// Thread-safe sweep counter for the disappearance test. The reaper's
/// `enumerate` closure is `@Sendable`; capturing a plain `var` from a
/// concurrent closure trips Swift 6 strict isolation.
nonisolated private final class SweepCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var _value: Int = 0
  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return _value
  }
  func increment() -> Int {
    lock.lock()
    _value += 1
    let snapshot = _value
    lock.unlock()
    return snapshot
  }
}

/// Verifies the reaper that kills orphaned processes whose cwd is under
/// `~/.supacool/repos/`. Without this safety net, Go-toolchain compile
/// workers (which run in their own process group and survive PTY
/// hangup) accumulate as ppid=1 zombies after a Ghostty surface closes.
@MainActor
struct WorktreeOrphanProcessReaperTests {
  // MARK: - Filter behavior

  @Test func orphanInsideReposIsTerminatedWithSIGTERMOnFirstObservation() {
    let snapshot = makeSnapshot(pid: 1001, ppid: 1, cwd: "/tmp/repos/foo/wt", ageSec: 600)
    let recorder = TerminationRecorder()
    let reaper = WorktreeOrphanProcessReaper(
      cwdPrefix: "/tmp/repos/",
      minimumOrphanAge: 180,
      now: { fixedNow },
      enumerate: { [snapshot] },
      terminate: { pid, signal in recorder.record(pid, signal) }
    )

    let acted = reaper.reap()

    #expect(acted == [1001])
    #expect(recorder.calls == [.init(pid: 1001, signal: SIGTERM)])
  }

  @Test func orphanOutsideReposIsIgnored() {
    let snapshot = makeSnapshot(pid: 1002, ppid: 1, cwd: "/Users/somebody/projects/foo", ageSec: 600)
    let recorder = TerminationRecorder()
    let reaper = WorktreeOrphanProcessReaper(
      cwdPrefix: "/tmp/repos/",
      minimumOrphanAge: 180,
      now: { fixedNow },
      enumerate: { [snapshot] },
      terminate: { pid, signal in recorder.record(pid, signal) }
    )

    let acted = reaper.reap()

    #expect(acted.isEmpty)
    #expect(recorder.calls.isEmpty)
  }

  @Test func nonOrphanIsIgnoredEvenIfInsideRepos() {
    let snapshot = makeSnapshot(pid: 1003, ppid: 4242, cwd: "/tmp/repos/foo/wt", ageSec: 600)
    let recorder = TerminationRecorder()
    let reaper = WorktreeOrphanProcessReaper(
      cwdPrefix: "/tmp/repos/",
      minimumOrphanAge: 180,
      now: { fixedNow },
      enumerate: { [snapshot] },
      terminate: { pid, signal in recorder.record(pid, signal) }
    )

    let acted = reaper.reap()

    #expect(acted.isEmpty)
    #expect(recorder.calls.isEmpty)
  }

  @Test func orphanYoungerThanThresholdIsIgnored() {
    let snapshot = makeSnapshot(pid: 1004, ppid: 1, cwd: "/tmp/repos/foo/wt", ageSec: 30)
    let recorder = TerminationRecorder()
    let reaper = WorktreeOrphanProcessReaper(
      cwdPrefix: "/tmp/repos/",
      minimumOrphanAge: 180,
      now: { fixedNow },
      enumerate: { [snapshot] },
      terminate: { pid, signal in recorder.record(pid, signal) }
    )

    let acted = reaper.reap()

    #expect(acted.isEmpty)
    #expect(recorder.calls.isEmpty)
  }

  // MARK: - Two-strike escalation

  @Test func survivorOfFirstSweepGetsSIGKILLOnSecondSweep() {
    let snapshot = makeSnapshot(pid: 2001, ppid: 1, cwd: "/tmp/repos/foo/wt", ageSec: 600)
    let recorder = TerminationRecorder()
    let reaper = WorktreeOrphanProcessReaper(
      cwdPrefix: "/tmp/repos/",
      minimumOrphanAge: 180,
      now: { fixedNow },
      enumerate: { [snapshot] },
      terminate: { pid, signal in recorder.record(pid, signal) }
    )

    _ = reaper.reap()
    _ = reaper.reap()

    #expect(recorder.calls == [
      .init(pid: 2001, signal: SIGTERM),
      .init(pid: 2001, signal: SIGKILL),
    ])
  }

  @Test func disappearedPIDIsForgottenSoNewArrivalGetsSIGTERMNotSIGKILL() {
    // First sweep sees pid 3001. Second sweep sees nothing (it died).
    // Third sweep sees pid 3001 again — but PIDs are reused, so the
    // reaper must have forgotten the first 3001 and treat this as a
    // fresh observation worth SIGTERM, not SIGKILL.
    let snapshotA = makeSnapshot(pid: 3001, ppid: 1, cwd: "/tmp/repos/foo/wt", ageSec: 600)
    let counter = SweepCounter()
    let recorder = TerminationRecorder()
    let reaper = WorktreeOrphanProcessReaper(
      cwdPrefix: "/tmp/repos/",
      minimumOrphanAge: 180,
      now: { fixedNow },
      enumerate: {
        let n = counter.increment()
        switch n {
        case 1, 3: return [snapshotA]
        default: return []
        }
      },
      terminate: { pid, signal in recorder.record(pid, signal) }
    )

    _ = reaper.reap()  // SIGTERM 3001
    _ = reaper.reap()  // empty — clears memory of 3001
    _ = reaper.reap()  // SIGTERM 3001 again (not SIGKILL)

    #expect(recorder.calls == [
      .init(pid: 3001, signal: SIGTERM),
      .init(pid: 3001, signal: SIGTERM),
    ])
  }

  @Test func multipleOrphansAreAllProcessed() {
    let recorder = TerminationRecorder()
    let reaper = WorktreeOrphanProcessReaper(
      cwdPrefix: "/tmp/repos/",
      minimumOrphanAge: 180,
      now: { fixedNow },
      enumerate: {
        [
          makeSnapshot(pid: 4001, ppid: 1, cwd: "/tmp/repos/a/wt", ageSec: 600),
          makeSnapshot(pid: 4002, ppid: 1, cwd: "/tmp/repos/b/wt", ageSec: 600),
          makeSnapshot(pid: 4003, ppid: 1, cwd: "/tmp/repos/c/wt", ageSec: 600),
        ]
      },
      terminate: { pid, signal in recorder.record(pid, signal) }
    )

    let acted = reaper.reap()

    #expect(Set(acted) == [4001, 4002, 4003])
    #expect(recorder.calls.count == 3)
    #expect(recorder.calls.allSatisfy { $0.signal == SIGTERM })
  }
}
