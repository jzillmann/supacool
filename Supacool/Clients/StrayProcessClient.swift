import ComposableArchitecture
import Darwin
import Foundation

private nonisolated let strayLogger = SupaLogger("Supacool.StrayProcesses")

/// Finds and stops detached processes (`ppid == 1`) that still run inside a
/// repo's worktrees, for the Worktree Janitor.
///
/// `WorktreeOwnedProcessTracker` stops such processes when Supacool itself
/// removes or parks a worktree. It cannot help when something else removes
/// the worktree — an agent's own script deleting a scratch worktree — or when
/// nobody removes anything: a dev server an agent started in the background
/// keeps its port and memory after the work is done. This client makes those
/// visible, so the Janitor can list them and stop them on request. It never
/// stops anything on its own.
nonisolated struct StrayProcessClient: Sendable {
  /// Every detached process of the current user whose cwd lies under one of
  /// `roots`, with its descendants. Processes younger than `minimumAge` are
  /// left out: a Go build briefly reparents its compile workers to launchd.
  var scan: @Sendable (_ roots: [String], _ minimumAge: TimeInterval) async -> [StrayProcessCandidate]
  /// SIGTERM each pid. Returns the pids that could not be signalled for a
  /// reason other than "already gone".
  var terminate: @Sendable (_ pids: [pid_t]) async -> [pid_t]
}

/// A detached process found under a scan root.
nonisolated struct StrayProcessCandidate: Equatable, Sendable {
  let pid: pid_t
  let cwd: String
  /// argv joined with spaces; the executable path when argv is unreadable.
  let command: String
  let startedAt: Date
  /// Children, grandchildren, … — stopped together with the process, because
  /// a `pnpm run dev` wrapper does not reliably pass SIGTERM on to its vite.
  let descendantPIDs: [pid_t]
}

extension StrayProcessClient: DependencyKey {
  static let liveValue = StrayProcessClient(
    scan: { roots, minimumAge in
      await Task.detached(priority: .utility) {
        scanStrayProcesses(roots: roots, minimumAge: minimumAge, now: Date())
      }.value
    },
    terminate: { pids in
      pids.filter { pid in
        guard kill(pid, SIGTERM) != 0 else {
          strayLogger.info("SIGTERM stray pid=\(pid)")
          return false
        }
        return errno != ESRCH
      }
    }
  )

  static let testValue = StrayProcessClient(
    scan: { _, _ in [] },
    terminate: { _ in [] }
  )
}

extension DependencyValues {
  var strayProcesses: StrayProcessClient {
    get { self[StrayProcessClient.self] }
    set { self[StrayProcessClient.self] = newValue }
  }
}

// MARK: - Live process table

private nonisolated func scanStrayProcesses(
  roots: [String],
  minimumAge: TimeInterval,
  now: Date
) -> [StrayProcessCandidate] {
  let normalizedRoots = roots.map(normalizePath).filter { $0 != "/" }
  guard !normalizedRoots.isEmpty else { return [] }
  let uid = getuid()
  let cutoff = now.addingTimeInterval(-minimumAge)

  var childrenByParent: [pid_t: [pid_t]] = [:]
  var detached: [(pid: pid_t, startedAt: Date)] = []
  for pid in listAllPIDs() {
    var bsd = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size else { continue }
    let ppid = pid_t(bsd.pbi_ppid)
    childrenByParent[ppid, default: []].append(pid)
    guard ppid == 1, bsd.pbi_uid == uid else { continue }
    let startedAt = Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec))
    guard startedAt <= cutoff else { continue }
    detached.append((pid, startedAt))
  }

  return detached.compactMap { entry in
    guard let cwd = currentDirectory(of: entry.pid),
      normalizedRoots.contains(where: { cwd == $0 || cwd.hasPrefix($0 + "/") })
    else { return nil }
    return StrayProcessCandidate(
      pid: entry.pid,
      cwd: cwd,
      command: commandLine(of: entry.pid) ?? "pid \(entry.pid)",
      startedAt: entry.startedAt,
      descendantPIDs: descendants(of: entry.pid, in: childrenByParent)
    )
  }
}

private nonisolated func listAllPIDs() -> [pid_t] {
  let stride = MemoryLayout<pid_t>.stride
  let bytesNeeded = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
  guard bytesNeeded > 0 else { return [] }
  var pids = [pid_t](repeating: 0, count: Int(bytesNeeded) / stride + 64)
  let bytesWritten = pids.withUnsafeMutableBufferPointer { buf in
    proc_listpids(UInt32(PROC_ALL_PIDS), 0, buf.baseAddress, Int32(buf.count * stride))
  }
  guard bytesWritten > 0 else { return [] }
  return pids.prefix(Int(bytesWritten) / stride).filter { $0 > 0 }
}

private nonisolated func currentDirectory(of pid: pid_t) -> String? {
  var vnode = proc_vnodepathinfo()
  let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
  guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnode, size) == size else { return nil }
  let path = withUnsafePointer(to: &vnode.pvi_cdir.vip_path) { tuple in
    tuple.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
  }
  return path.isEmpty ? nil : path
}

/// argv via `KERN_PROCARGS2`: an `Int32` argc, the exec path, NUL padding,
/// then argc NUL-terminated arguments.
private nonisolated func commandLine(of pid: pid_t) -> String? {
  var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
  var size = 0
  guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
  var buffer = [UInt8](repeating: 0, count: size)
  guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
  let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
  var index = MemoryLayout<Int32>.size
  while index < size, buffer[index] != 0 { index += 1 }  // exec path
  while index < size, buffer[index] == 0 { index += 1 }  // padding
  var arguments: [String] = []
  while arguments.count < argc, index < size {
    let start = index
    while index < size, buffer[index] != 0 { index += 1 }
    arguments.append(String(bytes: buffer[start..<index], encoding: .utf8) ?? "")
    index += 1
  }
  return arguments.isEmpty ? nil : arguments.joined(separator: " ")
}

nonisolated func descendants(of pid: pid_t, in childrenByParent: [pid_t: [pid_t]]) -> [pid_t] {
  var result: [pid_t] = []
  var queue = childrenByParent[pid] ?? []
  var seen: Set<pid_t> = [pid]
  while let next = queue.first {
    queue.removeFirst()
    guard seen.insert(next).inserted else { continue }
    result.append(next)
    queue.append(contentsOf: childrenByParent[next] ?? [])
  }
  return result
}

// MARK: - Classification

/// A stray process as the Janitor shows it.
nonisolated struct StrayProcess: Equatable, Identifiable, Sendable {
  nonisolated enum Status: Equatable, Sendable {
    /// No worktree of this repo contains the cwd any more.
    case worktreeGone
    /// The worktree exists, but no session card uses it.
    case noCard
    /// A session card still uses the worktree. Possibly wanted.
    case cardOnBoard
  }

  var id: pid_t { pid }
  let pid: pid_t
  let cwd: String
  let command: String
  let startedAt: Date
  let descendantPIDs: [pid_t]
  /// Inventory row whose worktree contains `cwd`; nil when `.worktreeGone`.
  let worktreePath: String?
  let status: Status

  /// The two states where nothing on the board can still want the process.
  var isPreselected: Bool { status != .cardOnBoard }
}

/// Attributes each candidate to the innermost inventory row containing its
/// cwd. Processes in the repo root itself are skipped: that is the user's own
/// checkout, not a worktree the Janitor manages.
nonisolated func classifyStrayProcesses(
  candidates: [StrayProcessCandidate],
  rows: [WorktreeInventoryEntry]
) -> [StrayProcess] {
  let rowsByDepth = rows.sorted { $0.id.count > $1.id.count }
  return candidates.compactMap { candidate in
    let cwd = normalizePath(candidate.cwd)
    let row = rowsByDepth.first { cwd == $0.id || cwd.hasPrefix($0.id + "/") }
    let status: StrayProcess.Status
    switch row?.status {
    case nil: status = .worktreeGone
    case .repoRoot?: return nil
    case .owned?: status = .cardOnBoard
    case .orphan?, .orphanDirty?: status = .noCard
    }
    return StrayProcess(
      pid: candidate.pid,
      cwd: cwd,
      command: candidate.command,
      startedAt: candidate.startedAt,
      descendantPIDs: candidate.descendantPIDs,
      worktreePath: row?.id,
      status: status
    )
  }
  .sorted { $0.startedAt < $1.startedAt }
}
