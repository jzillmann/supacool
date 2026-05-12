import Darwin
import Foundation

private let trackerLogger = SupaLogger("Terminal.OwnedProcessTracker")

/// Minimum age (seconds) a `ppid==1` process must reach before it
/// counts as "stably attributed" to a worktree. Avoids racing with
/// legitimate builds that briefly orphan children mid-spawn on macOS
/// (Go's compile workers, `go run`'s exec'd binary, etc.).
private let defaultMinimumOrphanAge: TimeInterval = 180

/// Snapshot of one process, used by `WorktreeOwnedProcessTracker` to
/// attribute live orphans to worktrees on each refresh.
struct OrphanProcessSnapshot: Sendable, Equatable, Hashable {
  let pid: pid_t
  let ppid: pid_t
  let cwd: String
  let executablePath: String?
  let startedAt: Date
}

/// A process the tracker has attributed to a worktree. Stored in
/// `WorktreeOwnedProcessTracker.adoptedByWorktree[worktreePath]`.
struct AdoptedProcess: Sendable, Equatable, Hashable {
  let pid: pid_t
  let cwd: String
  let executablePath: String?
  let startedAt: Date
  let adoptedAt: Date
}

/// Tracks every `ppid==1` process whose working directory is under
/// `~/.supacool/repos/` and attributes it to the worktree directory
/// (`<reposRoot>/<repo>/<worktree>`) it lives in. Refresh is
/// non-destructive — it never kills a process just for being old.
///
/// Termination happens only via `release(worktreePath:)`, called by
/// the worktree's lifecycle owner (archive, remove, all-sessions-
/// parked). That keeps long-running services (dev backends, vite,
/// pyomo, etc.) alive across surface lifecycles while still cleaning
/// up the original target — Go compile workers and `go run` binaries
/// left behind when the worktree itself goes away.
///
/// Background: when supacool tears down a Ghostty surface, the PTY
/// hangup delivers SIGHUP only to the foreground process group. Go's
/// build driver puts compile workers in their own process groups
/// (`cmd/go/internal/work/exec.go` sets `Setpgid: true`), so they
/// survive the hangup and reparent to launchd. The same happens to
/// `go run …` after it exec's a compiled binary — the binary keeps
/// running with `ppid == 1` after the parent shell dies. The previous
/// `WorktreeOrphanProcessReaper` treated *every* such orphan as a
/// leak and SIGTERM'd / SIGKILL'd it after 180s. That collateral-
/// killed dev-CLI services that intentionally use the same Setpgid
/// pattern in active worktrees.
@MainActor
final class WorktreeOwnedProcessTracker {
  private let cwdPrefix: String
  private let minimumOrphanAge: TimeInterval
  private let now: @Sendable () -> Date
  private let enumerate: @Sendable () -> [OrphanProcessSnapshot]
  private let terminate: @Sendable (pid_t, Int32) -> Void
  private(set) var adoptedByWorktree: [String: Set<AdoptedProcess>] = [:]

  init(
    cwdPrefix: String = SupacoolPaths.reposDirectory.path(percentEncoded: false),
    minimumOrphanAge: TimeInterval = defaultMinimumOrphanAge,
    now: @escaping @Sendable () -> Date = { Date() },
    enumerate: @escaping @Sendable () -> [OrphanProcessSnapshot] =
      WorktreeOwnedProcessTracker.defaultEnumerate,
    terminate: @escaping @Sendable (pid_t, Int32) -> Void =
      WorktreeOwnedProcessTracker.defaultTerminate,
  ) {
    self.cwdPrefix = cwdPrefix
    self.minimumOrphanAge = minimumOrphanAge
    self.now = now
    self.enumerate = enumerate
    self.terminate = terminate
  }

  /// Walks the process table and updates the per-worktree set of
  /// adopted PIDs. New orphans meeting the age threshold are adopted;
  /// PIDs whose process is no longer alive are dropped. Returns the
  /// snapshots newly adopted on this call, in observation order (used
  /// for telemetry / tests; ignore in production).
  @discardableResult
  func refresh() -> [AdoptedProcess] {
    let cutoff = now().addingTimeInterval(-minimumOrphanAge)
    let snapshots = enumerate().filter { snap in
      snap.ppid == 1
        && snap.cwd.hasPrefix(cwdPrefix)
        && snap.startedAt <= cutoff
    }

    let livePIDs = Set(snapshots.map(\.pid))
    let alreadyAdoptedPIDs = Set(adoptedByWorktree.values.flatMap { $0.map(\.pid) })
    var newlyAdopted: [AdoptedProcess] = []
    let adoptedAt = now()

    for snap in snapshots where !alreadyAdoptedPIDs.contains(snap.pid) {
      guard let worktreePath = resolveWorktreePath(cwd: snap.cwd) else { continue }
      let adopted = AdoptedProcess(
        pid: snap.pid,
        cwd: snap.cwd,
        executablePath: snap.executablePath,
        startedAt: snap.startedAt,
        adoptedAt: adoptedAt,
      )
      adoptedByWorktree[worktreePath, default: []].insert(adopted)
      newlyAdopted.append(adopted)
      trackerLogger.info(
        "Adopted pid=\(snap.pid) worktree=\(worktreePath) "
          + "exe=\(snap.executablePath ?? "?") "
          + "ageSec=\(Int(now().timeIntervalSince(snap.startedAt)))"
      )
    }

    // Drop PIDs whose process has died since the last refresh. Live
    // PIDs returned by `enumerate` stay; for everything else, fall
    // back to `kill(pid, 0)` (cheap) before deciding to drop.
    for (path, processes) in adoptedByWorktree {
      let alive = processes.filter { process in
        if livePIDs.contains(process.pid) { return true }
        return kill(process.pid, 0) == 0
      }
      if alive.isEmpty {
        adoptedByWorktree.removeValue(forKey: path)
      } else if alive != processes {
        adoptedByWorktree[path] = alive
      }
    }

    return newlyAdopted
  }

  /// Terminates every process attributed to `worktreePath`. SIGTERM
  /// only — by design, no immediate SIGKILL follow-up, because the
  /// triggers (archive / remove / all-parked) are user-initiated and
  /// can afford a polite shutdown. The next `refresh()` reclaims
  /// nothing for this path (the bucket is removed). Returns the PIDs
  /// signalled.
  @discardableResult
  func release(worktreePath: String) -> [pid_t] {
    // Tracker keys never have a trailing slash; callers occasionally
    // pass a normalised-with-slash form (the persisted
    // `AgentSession.currentWorkspacePath` for example), so trim once
    // before the lookup.
    var key = worktreePath
    while key.count > 1 && key.hasSuffix("/") { key.removeLast() }
    guard let processes = adoptedByWorktree.removeValue(forKey: key) else { return [] }
    var acted: [pid_t] = []
    for proc in processes {
      trackerLogger.info(
        "SIGTERM owned pid=\(proc.pid) worktree=\(key) "
          + "exe=\(proc.executablePath ?? "?")"
      )
      terminate(proc.pid, SIGTERM)
      acted.append(proc.pid)
    }
    return acted
  }

  /// Returns the absolute worktree directory that owns a process
  /// whose `cwd` lives under `cwdPrefix`. Expected layout is
  /// `<cwdPrefix>/<repo>/<worktree>/<…>` — i.e. supacool's standard
  /// `~/.supacool/repos/<repo>/<worktree>/…`. Returns nil for cwds
  /// that don't have enough segments below the prefix to identify
  /// a worktree.
  private func resolveWorktreePath(cwd: String) -> String? {
    guard cwd.hasPrefix(cwdPrefix) else { return nil }
    let suffix = cwd.dropFirst(cwdPrefix.count)
    let parts = suffix.split(separator: "/", omittingEmptySubsequences: true)
    guard parts.count >= 2 else { return nil }
    var prefix = cwdPrefix
    if prefix.hasSuffix("/") { prefix.removeLast() }
    return "\(prefix)/\(parts[0])/\(parts[1])"
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
  /// for cwd/exepath on processes the tracker would discard anyway.
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
          startedAt: startedAt,
        )
      )
    }

    return results
  }
}
