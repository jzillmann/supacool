import ComposableArchitecture
import Foundation

private nonisolated let footprintLogger = SupaLogger("Supacool.Footprint")

/// Samples the current process and its descendants via `ps` to produce a
/// memory snapshot. Used by the board-header footprint chip and by the
/// Analyze-Memory sheet that exposes the same diagnostic walk I do by
/// hand via `ps -eo pid,ppid,rss,command` during incidents.
///
/// Rationale for `ps` over a native `proc_listchildpids` approach: we
/// need transitive descendants (children of children etc.), we need RSS,
/// and we need the command line — all three are one `ps` invocation
/// with zero entitlement surface. A native implementation is faster but
/// adds Objective-C surface area for ~1 sample / 20 seconds that we
/// don't need right now.
nonisolated struct ProcessFootprintClient: Sendable {
  /// Samples the process tree rooted at `rootPID` and returns a snapshot.
  /// Passing `ProcessInfo.processInfo.processIdentifier` scopes the
  /// walk to this app and everything it spawned.
  var sample: @Sendable (_ rootPID: Int32) async throws -> ProcessFootprintSnapshot
}

nonisolated struct ProcessFootprintSnapshot: Equatable, Sendable {
  let sampledAt: Date
  /// Raw RSS of the root process itself, in bytes.
  let rootBytes: UInt64
  /// RSS of every descendant (excludes root), in bytes.
  let descendantBytes: UInt64
  /// Top-level child subtrees, sorted by aggregated RSS descending.
  let subtrees: [Subtree]
  /// Total number of descendant processes (flat count).
  let descendantCount: Int

  /// Sum of everything in the tree including the root.
  var totalBytes: UInt64 { rootBytes + descendantBytes }

  struct Subtree: Equatable, Sendable, Identifiable {
    /// PID of the top-level child (direct child of the root).
    let id: Int32
    /// Command line of the subtree root, truncated to a reasonable length.
    let rootCommand: String
    /// RSS of the top-level child alone.
    let rootBytes: UInt64
    /// Aggregated RSS of the top-level child plus all descendants.
    let aggregatedBytes: UInt64
    /// Process count in this subtree (including the root).
    let processCount: Int
    /// The single heaviest process in the subtree — useful for "this
    /// subtree is heavy because of X". Nil if no descendants.
    let heaviestLeaf: LeafProcess?
  }

  struct LeafProcess: Equatable, Sendable {
    let pid: Int32
    let rssBytes: UInt64
    let command: String
  }
}

extension ProcessFootprintClient: DependencyKey {
  static let liveValue: ProcessFootprintClient = live()

  static func live(shell: ShellClient = .liveValue) -> ProcessFootprintClient {
    ProcessFootprintClient(
      sample: { rootPID in
        // `=` suffix on each column suppresses headers and gives us
        // space-separated fields with the command as the trailing
        // tail. `ps -axo` omits the login shells of other users, which
        // is what we want — we only care about this app's tree.
        let envURL = URL(fileURLWithPath: "/usr/bin/env")
        let args = ["ps", "-axo", "pid=,ppid=,rss=,command="]
        let output: ShellOutput
        do {
          output = try await shell.run(envURL, args, nil)
        } catch {
          footprintLogger.warning(
            "ps sampling failed: \(error.localizedDescription)"
          )
          throw error
        }
        let parsed = parsePSOutput(output.stdout)
        let snapshot = buildSnapshot(from: parsed, rootPID: rootPID, now: Date())
        return snapshot
      }
    )
  }

  static let testValue = ProcessFootprintClient(
    sample: { _ in
      struct UnimplementedSample: Error {}
      throw UnimplementedSample()
    }
  )
}

extension DependencyValues {
  var processFootprint: ProcessFootprintClient {
    get { self[ProcessFootprintClient.self] }
    set { self[ProcessFootprintClient.self] = newValue }
  }
}

// MARK: - Parsing

/// One parsed row from `ps -axo pid=,ppid=,rss=,command=`.
nonisolated struct RawProcess: Equatable, Sendable {
  let pid: Int32
  let ppid: Int32
  /// macOS `ps` emits RSS in KB.
  let rssKB: UInt64
  let command: String
}

/// Parses `ps` output into a list of rows. Malformed lines are skipped
/// silently — we'd rather show a partial snapshot than lose it to one
/// weird row. RSS is converted to bytes (×1024) by `buildSnapshot`.
nonisolated func parsePSOutput(_ output: String) -> [RawProcess] {
  var result: [RawProcess] = []
  result.reserveCapacity(512)
  for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
    // Skip leading whitespace, then split on the first three whitespace
    // boundaries — everything after that is the command (which itself
    // can contain spaces). `ps` aligns columns with leading spaces so a
    // trimmed split-by-whitespace is safe for the three numeric fields.
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { continue }
    // Manual 4-way split: pid, ppid, rss, then the rest as command.
    var cursor = trimmed.startIndex
    guard let (pid, afterPID) = scanInt(in: trimmed, from: cursor) else { continue }
    cursor = afterPID
    cursor = skipWhitespace(in: trimmed, from: cursor)
    guard let (ppid, afterPPID) = scanInt(in: trimmed, from: cursor) else { continue }
    cursor = afterPPID
    cursor = skipWhitespace(in: trimmed, from: cursor)
    guard let (rss, afterRSS) = scanUInt(in: trimmed, from: cursor) else { continue }
    cursor = afterRSS
    cursor = skipWhitespace(in: trimmed, from: cursor)
    let command = String(trimmed[cursor...])
    guard !command.isEmpty else { continue }
    result.append(
      RawProcess(pid: Int32(pid), ppid: Int32(ppid), rssKB: rss, command: command)
    )
  }
  return result
}

/// Builds the snapshot by walking descendants of `rootPID` breadth-first,
/// aggregating RSS per top-level child subtree. Bytes are the `ps` KB
/// number × 1024.
nonisolated func buildSnapshot(
  from rows: [RawProcess],
  rootPID: Int32,
  now: Date
) -> ProcessFootprintSnapshot {
  let byPID = Dictionary(uniqueKeysWithValues: rows.map { ($0.pid, $0) })
  var childrenOf: [Int32: [Int32]] = [:]
  for row in rows {
    childrenOf[row.ppid, default: []].append(row.pid)
  }

  let rootBytes = UInt64(byPID[rootPID]?.rssKB ?? 0) * 1024
  var descendantBytes: UInt64 = 0
  var descendantCount = 0
  var subtrees: [ProcessFootprintSnapshot.Subtree] = []

  for topLevelPID in (childrenOf[rootPID] ?? []) {
    guard let topRow = byPID[topLevelPID] else { continue }
    var subtreeRows: [RawProcess] = [topRow]
    var queue: [Int32] = [topLevelPID]
    while let cur = queue.first {
      queue.removeFirst()
      for childPID in (childrenOf[cur] ?? []) {
        if let row = byPID[childPID] {
          subtreeRows.append(row)
          queue.append(childPID)
        }
      }
    }
    let aggregatedKB = subtreeRows.reduce(UInt64(0)) { $0 + $1.rssKB }
    let aggregatedBytes = aggregatedKB * 1024
    descendantBytes += aggregatedBytes
    descendantCount += subtreeRows.count
    let heaviest = subtreeRows.max(by: { $0.rssKB < $1.rssKB })
    let heaviestLeaf = heaviest.map {
      ProcessFootprintSnapshot.LeafProcess(
        pid: $0.pid,
        rssBytes: UInt64($0.rssKB) * 1024,
        command: $0.command
      )
    }
    subtrees.append(
      ProcessFootprintSnapshot.Subtree(
        id: topLevelPID,
        rootCommand: topRow.command,
        rootBytes: UInt64(topRow.rssKB) * 1024,
        aggregatedBytes: aggregatedBytes,
        processCount: subtreeRows.count,
        heaviestLeaf: heaviestLeaf
      )
    )
  }

  subtrees.sort { $0.aggregatedBytes > $1.aggregatedBytes }

  return ProcessFootprintSnapshot(
    sampledAt: now,
    rootBytes: rootBytes,
    descendantBytes: descendantBytes,
    subtrees: subtrees,
    descendantCount: descendantCount
  )
}

// MARK: - Lightweight scanners
//
// Avoids Scanner / regex overhead for what's effectively a per-second
// hot path. The `ps` output is stable enough that a two-pass split
// would also work, but these scanners read cleaner.

nonisolated private func scanInt(in s: String, from: String.Index) -> (Int64, String.Index)? {
  var cursor = from
  let start = cursor
  while cursor < s.endIndex, s[cursor].isASCII, s[cursor].isNumber {
    cursor = s.index(after: cursor)
  }
  guard cursor > start, let value = Int64(s[start..<cursor]) else { return nil }
  return (value, cursor)
}

nonisolated private func scanUInt(in s: String, from: String.Index) -> (UInt64, String.Index)? {
  var cursor = from
  let start = cursor
  while cursor < s.endIndex, s[cursor].isASCII, s[cursor].isNumber {
    cursor = s.index(after: cursor)
  }
  guard cursor > start, let value = UInt64(s[start..<cursor]) else { return nil }
  return (value, cursor)
}

nonisolated private func skipWhitespace(in s: String, from: String.Index) -> String.Index {
  var cursor = from
  while cursor < s.endIndex, s[cursor].isWhitespace {
    cursor = s.index(after: cursor)
  }
  return cursor
}
