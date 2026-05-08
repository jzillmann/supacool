import Darwin
import Foundation

private let reaperLogger = SupaLogger("Terminal.OrphanReaper")

/// Default minimum age (seconds) before an orphan is considered stale
/// enough to terminate. Avoids racing with legitimate builds that
/// briefly orphan children mid-spawn on macOS.
private let defaultMinimumOrphanAge: TimeInterval = 180

/// Snapshot of one process, used by `WorktreeOrphanProcessReaper` to
/// decide whether the process is a stale orphan that should be killed.
struct OrphanProcessSnapshot: Sendable, Equatable, Hashable {
  let pid: pid_t
  let ppid: pid_t
  let cwd: String
  let executablePath: String?
  let startedAt: Date
}

/// Periodically walks orphaned (`ppid == 1`) processes whose working
/// directory is under `~/.supacool/repos/` and terminates them.
///
/// Background: when supacool tears down a Ghostty surface, the PTY
/// hangup only delivers SIGHUP to the foreground process group. Go's
/// build driver puts compile workers in their own process groups
/// (`cmd/go/internal/work/exec.go` sets `Setpgid: true`), so they
/// survive the hangup and reparent to launchd. The same happens to
/// `go run …` after it exec's a compiled binary — the binary keeps
/// running with `ppid == 1` after the parent shell dies.
///
/// Two-strike escalation: orphans seen for the first time get SIGTERM;
/// if they reappear in the next sweep they get SIGKILL. No internal
/// `Task.sleep` needed — the next tick provides the grace period and
/// keeps the reaper synchronously testable.
@MainActor
final class WorktreeOrphanProcessReaper {
  private let cwdPrefix: String
  private let minimumOrphanAge: TimeInterval
  private let now: @Sendable () -> Date
  private let enumerate: @Sendable () -> [OrphanProcessSnapshot]
  private let terminate: @Sendable (pid_t, Int32) -> Void
  private var previousCandidatePIDs: Set<pid_t> = []

  init(
    cwdPrefix: String = SupacoolPaths.reposDirectory.path(percentEncoded: false),
    minimumOrphanAge: TimeInterval = defaultMinimumOrphanAge,
    now: @escaping @Sendable () -> Date = { Date() },
    enumerate: @escaping @Sendable () -> [OrphanProcessSnapshot] = WorktreeOrphanProcessReaper.defaultEnumerate,
    terminate: @escaping @Sendable (pid_t, Int32) -> Void = WorktreeOrphanProcessReaper.defaultTerminate
  ) {
    self.cwdPrefix = cwdPrefix
    self.minimumOrphanAge = minimumOrphanAge
    self.now = now
    self.enumerate = enumerate
    self.terminate = terminate
  }

  /// Performs one sweep. Returns the PIDs the reaper acted on, in the
  /// order it acted on them (telemetry / test verification).
  ///
  /// Two-strike rule: a candidate seen for the first time gets SIGTERM;
  /// if it appears again on the next call (i.e. survived SIGTERM) it
  /// gets SIGKILL. PIDs that disappear between calls are dropped from
  /// the previous-candidate set automatically.
  @discardableResult
  func reap() -> [pid_t] {
    let cutoff = now().addingTimeInterval(-minimumOrphanAge)
    let candidates = enumerate().filter { snap in
      snap.ppid == 1
        && snap.cwd.hasPrefix(cwdPrefix)
        && snap.startedAt <= cutoff
    }

    var acted: [pid_t] = []
    for snap in candidates {
      let signal = previousCandidatePIDs.contains(snap.pid) ? SIGKILL : SIGTERM
      let signalName = signal == SIGKILL ? "SIGKILL" : "SIGTERM"
      reaperLogger.info(
        "\(signalName) orphan pid=\(snap.pid) cwd=\(snap.cwd) "
          + "exe=\(snap.executablePath ?? "?") "
          + "ageSec=\(Int(now().timeIntervalSince(snap.startedAt)))"
      )
      terminate(snap.pid, signal)
      acted.append(snap.pid)
    }

    previousCandidatePIDs = Set(candidates.map(\.pid))
    return acted
  }

  // MARK: - Defaults wired to the live OS.

  nonisolated static let defaultEnumerate: @Sendable () -> [OrphanProcessSnapshot] = {
    enumerateOrphanedProcesses()
  }

  nonisolated static let defaultTerminate: @Sendable (pid_t, Int32) -> Void = { pid, signal in
    _ = kill(pid, signal)
  }

  /// Enumerates **only** processes with `ppid == 1`. Filtering inside
  /// the enumerator avoids tens of thousands of `proc_pidinfo` calls
  /// for cwd/exepath on processes the reaper would discard anyway.
  /// On a typical macOS workstation orphans number in the single
  /// digits while total processes can exceed a thousand.
  private nonisolated static func enumerateOrphanedProcesses() -> [OrphanProcessSnapshot] {
    let pidStride = MemoryLayout<pid_t>.stride
    let bytesNeeded = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
    guard bytesNeeded > 0 else { return [] }

    let capacity = Int(bytesNeeded) / pidStride + 64  // headroom for races
    var pids = [pid_t](repeating: 0, count: capacity)
    let bytesWritten = pids.withUnsafeMutableBufferPointer { buf -> Int32 in
      proc_listpids(
        UInt32(PROC_ALL_PIDS),
        0,
        buf.baseAddress,
        Int32(buf.count * pidStride)
      )
    }
    guard bytesWritten > 0 else { return [] }
    let pidCount = Int(bytesWritten) / pidStride

    let bsdInfoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
    let vnodeInfoSize = Int32(MemoryLayout<proc_vnodepathinfo>.size)

    var results: [OrphanProcessSnapshot] = []
    results.reserveCapacity(8)

    for index in 0..<pidCount {
      let pid = pids[index]
      guard pid > 0 else { continue }

      var bsd = proc_bsdinfo()
      let bsdResult = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdInfoSize)
      guard bsdResult == bsdInfoSize else { continue }
      // Fast-path: skip non-orphans before paying for the cwd lookup.
      guard bsd.pbi_ppid == 1 else { continue }

      var vnode = proc_vnodepathinfo()
      let vnodeResult = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnode, vnodeInfoSize)
      guard vnodeResult == vnodeInfoSize else { continue }

      let cwd = withUnsafePointer(to: &vnode.pvi_cdir.vip_path) { tuplePtr -> String in
        tuplePtr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { cstr in
          String(cString: cstr)
        }
      }
      guard !cwd.isEmpty else { continue }

      // Apple defines PROC_PIDPATHINFO_MAXSIZE as `4 * MAXPATHLEN`, but
      // the macro is not imported into Swift; spell it out.
      var pathBuf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
      let pathLen = pathBuf.withUnsafeMutableBufferPointer { buf -> Int32 in
        proc_pidpath(pid, buf.baseAddress, UInt32(buf.count))
      }
      let exePath: String? = pathLen > 0
        ? pathBuf.withUnsafeBufferPointer { buf in buf.baseAddress.map { String(cString: $0) } }
        : nil

      let startedAt = Date(
        timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec)
          + TimeInterval(bsd.pbi_start_tvusec) / 1_000_000
      )

      results.append(
        OrphanProcessSnapshot(
          pid: pid,
          ppid: pid_t(bsd.pbi_ppid),
          cwd: cwd,
          executablePath: exePath,
          startedAt: startedAt
        )
      )
    }

    return results
  }
}
