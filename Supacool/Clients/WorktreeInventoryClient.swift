import ComposableArchitecture
import Foundation

private nonisolated let inventoryLogger = SupaLogger("Supacool.WorktreeInventory")

/// Supacool-owned worktree inventory layer: enumerates every worktree
/// registered for a repo (regardless of whether a live Supacool session
/// references it) and gathers size + git metadata on a per-row basis so
/// the "Manage Worktrees…" sheet can stream progress into a table.
///
/// Split into four deliberately-narrow closures so the UI can call them
/// independently and cancel per-row:
///
/// - `list`        → `git worktree list --porcelain`. Cheap. One call per scan.
/// - `measure`     → `du -sk`. Slow (recurses node_modules). One call per row,
///                   parallelized by the caller with bounded concurrency.
/// - `gitMetadata` → bundled `git log -1 / status --porcelain / rev-list`.
///                   Per-row, fast.
/// - `diffStat`    → `git diff --stat <base>...HEAD`. On demand only, when
///                   the user expands a row.
///
/// Supacool-specific — lives under `Supacool/`. The existing upstream
/// `GitClient.worktrees(for:)` is session-oriented (uses `wt ls --json`
/// with bundled-binary resolution). This client speaks plain porcelain so
/// tests can stub a `ShellClient` without touching `Bundle.main`.
nonisolated struct WorktreeInventoryClient: Sendable {
  /// All non-bare worktrees registered for `repoRoot`. Fast — reads
  /// git's admin records only, never touches worktree contents.
  var list: @Sendable (_ repoRoot: URL) async throws -> [GitWtWorktreeEntry]

  /// Disk footprint of `path` in bytes. Slow on cold caches — `du -sk`
  /// recurses into `node_modules`. Caller is expected to parallelize
  /// across rows with a concurrency cap.
  var measure: @Sendable (_ path: URL) async throws -> UInt64

  /// HEAD commit + uncommitted count + ahead/behind vs `baseRef`.
  /// Batched so a row can go from "loading" to "ready" in one await.
  var gitMetadata:
    @Sendable (_ path: URL, _ baseRef: String) async throws -> WorktreeInventoryGitMetadata

  /// `git diff --stat <baseRef>...HEAD`, raw. Loaded only when the user
  /// expands a row — avoid paying for it on every scan.
  var diffStat: @Sendable (_ path: URL, _ baseRef: String) async throws -> String
}

/// Bundled result of the three cheap per-row git calls. Any field can be
/// `nil` if the underlying call failed — the row renders "—" for missing
/// pieces rather than failing the whole scan.
nonisolated struct WorktreeInventoryGitMetadata: Equatable, Sendable {
  var lastCommit: WorktreeInventoryEntry.LastCommit?
  var uncommittedCount: Int
  var aheadBehind: WorktreeInventoryEntry.AheadBehind?

  init(
    lastCommit: WorktreeInventoryEntry.LastCommit? = nil,
    uncommittedCount: Int = 0,
    aheadBehind: WorktreeInventoryEntry.AheadBehind? = nil
  ) {
    self.lastCommit = lastCommit
    self.uncommittedCount = uncommittedCount
    self.aheadBehind = aheadBehind
  }
}

extension WorktreeInventoryClient: DependencyKey {
  static let liveValue = live()

  static func live(shell: ShellClient = .liveValue) -> WorktreeInventoryClient {
    let env = URL(fileURLWithPath: "/usr/bin/env")
    return WorktreeInventoryClient(
      list: { repoRoot in
        let output = try await shell.runLogin(
          env,
          ["git", "-C", repoRoot.path(percentEncoded: false), "worktree", "list", "--porcelain"],
          nil,
          log: false
        )
        return parseWorktreePorcelain(output.stdout)
      },
      measure: { path in
        // `du -sk` → 1K-block count + tab + path. macOS default block
        // size is 1024, so bytes = blocks * 1024. We discard stderr
        // (permission denies on deleted sub-paths etc.) but still want
        // whatever we did measure.
        let output = try await shell.run(
          env,
          ["du", "-sk", path.path(percentEncoded: false)],
          nil
        )
        guard let bytes = parseDuBytes(output.stdout) else {
          inventoryLogger.warning(
            "du -sk returned unparseable output for \(path.path(percentEncoded: false)): "
              + output.stdout
          )
          return 0
        }
        return bytes
      },
      gitMetadata: { path, baseRef in
        var metadata = WorktreeInventoryGitMetadata()
        let repoPath = path.path(percentEncoded: false)

        // Log: %H (full sha), %cI (committer date ISO-8601 strict), %s
        // (subject). Separated by \x1f so subjects containing tabs or
        // pipes don't confuse the parser.
        if let out = try? await shell.run(
          env,
          [
            "git", "-C", repoPath, "log", "-1",
            "--format=%H%x1f%cI%x1f%s",
          ],
          nil
        ) {
          metadata.lastCommit = parseLastCommit(out.stdout)
        }

        // Count uncommitted files via porcelain — empty output means
        // clean; each non-empty line is one change entry.
        if let out = try? await shell.run(
          env,
          ["git", "-C", repoPath, "status", "--porcelain"],
          nil
        ) {
          metadata.uncommittedCount = parsePorcelainLineCount(out.stdout)
        }

        // `--left-right --count baseRef...HEAD` → "<behind>\t<ahead>".
        // (left = reachable from baseRef not HEAD = behind;
        //  right = reachable from HEAD not baseRef = ahead.)
        if let out = try? await shell.run(
          env,
          [
            "git", "-C", repoPath, "rev-list",
            "--left-right", "--count", "\(baseRef)...HEAD",
          ],
          nil
        ) {
          metadata.aheadBehind = parseAheadBehind(out.stdout)
        }

        return metadata
      },
      diffStat: { path, baseRef in
        let out = try await shell.run(
          env,
          [
            "git", "-C", path.path(percentEncoded: false),
            "diff", "--stat", "\(baseRef)...HEAD",
          ],
          nil
        )
        return out.stdout
      }
    )
  }

  static let testValue = WorktreeInventoryClient(
    list: { _ in
      struct UnimplementedList: Error {}
      throw UnimplementedList()
    },
    measure: { _ in
      struct UnimplementedMeasure: Error {}
      throw UnimplementedMeasure()
    },
    gitMetadata: { _, _ in
      struct UnimplementedMetadata: Error {}
      throw UnimplementedMetadata()
    },
    diffStat: { _, _ in
      struct UnimplementedDiff: Error {}
      throw UnimplementedDiff()
    }
  )
}

extension DependencyValues {
  var worktreeInventory: WorktreeInventoryClient {
    get { self[WorktreeInventoryClient.self] }
    set { self[WorktreeInventoryClient.self] = newValue }
  }
}

// MARK: - Classification

/// Decide, for each worktree in `entries`, whether it's owned by a live
/// Supacool session, the repo root itself, or an orphan eligible for
/// deletion. Pure, synchronous — the dirty bit that distinguishes
/// `.orphan` from `.orphanDirty` is layered on later by the reducer
/// after `gitMetadata` arrives.
///
/// Matching is done on normalized paths (`standardizedFileURL.path`)
/// so trailing slashes and `..` components don't cause false orphans.
/// Session attachment is checked against **both** `worktreeID` (the
/// immutable state-lookup key) and `currentWorkspacePath` (mutated by
/// the convert-to-worktree popover) — missing either would mis-flag
/// converted sessions as orphans.
nonisolated func classifyWorktreeInventory(
  entries: [GitWtWorktreeEntry],
  sessions: [AgentSession],
  repositoryID: String
) -> [WorktreeInventoryEntry] {
  let normalizedRepo = normalizePath(repositoryID)
  // Pre-compute a lookup of `normalized session-path → session` so the
  // per-entry classifier is O(1) regardless of session count.
  var ownerByPath: [String: AgentSession] = [:]
  for session in sessions where session.repositoryID == repositoryID {
    let worktreeKey = normalizePath(session.worktreeID)
    ownerByPath[worktreeKey] = session
    let currentKey = normalizePath(session.currentWorkspacePath)
    if currentKey != worktreeKey {
      // Only overwrite if we don't already have an owner for this key —
      // the immutable `worktreeID` match wins over the mutable
      // `currentWorkspacePath` match when both sessions reference the
      // same path for different reasons.
      ownerByPath[currentKey, default: session] = ownerByPath[currentKey] ?? session
    }
  }

  return entries
    .filter { !$0.isBare }
    .map { entry in
      let entryPath = normalizePath(entry.path)
      let status: WorktreeInventoryEntry.Status
      if entryPath == normalizedRepo {
        status = .repoRoot
      } else if let owner = ownerByPath[entryPath] {
        status = .owned(sessionID: owner.id, displayName: owner.displayName)
      } else {
        status = .orphan
      }

      let url = URL(fileURLWithPath: entry.path)
      let branch = entry.branch.isEmpty ? nil : entry.branch
      return WorktreeInventoryEntry(
        id: entryPath,
        name: url.lastPathComponent,
        branch: branch,
        head: entry.head,
        status: status
      )
    }
}

/// Apply a fresh uncommitted count to an already-classified row. Bumps
/// `.orphan` → `.orphanDirty` when the count is non-zero so the UI can
/// surface the "you'd lose local work" warning without recomputing the
/// full classification.
nonisolated func applyUncommittedCount(
  _ count: Int,
  to entry: WorktreeInventoryEntry
) -> WorktreeInventoryEntry {
  var updated = entry
  updated.uncommittedCount = count
  if count > 0, case .orphan = entry.status {
    updated.status = .orphanDirty
  }
  return updated
}

// MARK: - Parsers

/// Parse `git worktree list --porcelain` output. Records are separated
/// by blank lines; each record is a sequence of `key value` pairs
/// (`worktree <path>`, `HEAD <sha>`, `branch <ref>`) plus keyword lines
/// (`bare`, `detached`). Lines we don't recognize are ignored.
nonisolated func parseWorktreePorcelain(_ raw: String) -> [GitWtWorktreeEntry] {
  var entries: [GitWtWorktreeEntry] = []
  var currentPath: String?
  var currentHead: String = ""
  var currentBranch: String = ""
  var currentBare: Bool = false

  func flush() {
    guard let path = currentPath else { return }
    entries.append(
      GitWtWorktreeEntry(
        branch: currentBranch,
        path: path,
        head: currentHead,
        isBare: currentBare
      )
    )
    currentPath = nil
    currentHead = ""
    currentBranch = ""
    currentBare = false
  }

  for rawLine in raw.split(whereSeparator: \.isNewline) {
    let line = String(rawLine)
    if line.isEmpty {
      flush()
      continue
    }
    if let path = stripPrefix("worktree ", from: line) {
      // A new record may start without a preceding blank line if git
      // truncated the trailing newline. Flush defensively.
      if currentPath != nil { flush() }
      currentPath = path
    } else if let head = stripPrefix("HEAD ", from: line) {
      currentHead = head
    } else if let ref = stripPrefix("branch ", from: line) {
      // Porcelain prints full refnames like `refs/heads/main` — strip
      // to match what `wt ls --json` stores in `GitWtWorktreeEntry.branch`.
      currentBranch =
        ref.hasPrefix("refs/heads/")
        ? String(ref.dropFirst("refs/heads/".count))
        : ref
    } else if line == "bare" {
      currentBare = true
    }
    // "detached", "locked", "prunable" → branch stays empty, which is
    // how GitWtWorktreeEntry already represents detached worktrees.
  }
  flush()
  return entries
}

/// `du -sk` prints `<blocks>\t<path>\n`. Returns nil if the first field
/// isn't an integer. macOS blocks are 1024 bytes.
nonisolated func parseDuBytes(_ raw: String) -> UInt64? {
  let firstField =
    raw.split(whereSeparator: { $0 == "\t" || $0.isWhitespace })
    .first
    .map(String.init) ?? ""
  guard let blocks = UInt64(firstField) else { return nil }
  return blocks * 1024
}

/// Parse one-liner `git log -1 --format=%H%x1f%cI%x1f%s` output.
/// Returns nil when the repo has no commits yet (empty output) or the
/// output doesn't contain the expected separators.
nonisolated func parseLastCommit(_ raw: String) -> WorktreeInventoryEntry.LastCommit? {
  let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else { return nil }
  let parts = trimmed.split(separator: "\u{1F}", maxSplits: 2, omittingEmptySubsequences: false)
  guard parts.count == 3 else { return nil }
  let hash = String(parts[0])
  let dateString = String(parts[1])
  let subject = String(parts[2])
  // Swift-native Sendable `.iso8601` parse strategy — avoids pulling a
  // non-Sendable ISO8601DateFormatter into module scope.
  guard !hash.isEmpty, let date = try? Date(dateString, strategy: .iso8601) else { return nil }
  return WorktreeInventoryEntry.LastCommit(
    date: date,
    shortHash: String(hash.prefix(7)),
    subject: subject
  )
}

/// Count non-empty lines of `git status --porcelain` output.
nonisolated func parsePorcelainLineCount(_ raw: String) -> Int {
  raw.split(whereSeparator: \.isNewline)
    .lazy
    .filter { !$0.isEmpty }
    .count
}

/// Parse `git rev-list --left-right --count <base>...HEAD` output.
/// Format: `<behind>\t<ahead>\n`. Returns nil when either side can't be
/// parsed as Int (typically: base ref doesn't exist locally).
nonisolated func parseAheadBehind(_ raw: String) -> WorktreeInventoryEntry.AheadBehind? {
  let fields =
    raw.trimmingCharacters(in: .whitespacesAndNewlines)
    .split(whereSeparator: { $0 == "\t" || $0.isWhitespace })
    .map(String.init)
  guard fields.count == 2,
    let behind = Int(fields[0]),
    let ahead = Int(fields[1])
  else { return nil }
  return WorktreeInventoryEntry.AheadBehind(ahead: ahead, behind: behind)
}

// MARK: - Helpers

/// Normalize a filesystem path for comparison: resolves `..` / `.`
/// components, drops trailing slashes, and decodes percent escapes.
/// Does **not** resolve symlinks — keeps `/tmp` distinct from
/// `/private/tmp` intentionally, since Supacool stores paths as the
/// user supplied them and forcing symlink resolution could mis-match
/// registered repos on hosts where $TMPDIR points through a symlink.
nonisolated func normalizePath(_ path: String) -> String {
  var result = URL(fileURLWithPath: path).standardizedFileURL.path(percentEncoded: false)
  // `URL(fileURLWithPath:)` preserves trailing slashes whenever the
  // input ended with one ("is directory"). Strip them explicitly so
  // "/repos/foo/" and "/repos/foo" hash-match in ownerByPath lookups.
  while result.count > 1, result.hasSuffix("/") {
    result.removeLast()
  }
  return result
}

/// Drop a literal prefix if present; returns nil otherwise. Free
/// function (vs. String extension) so it stays nonisolated under
/// Swift 6's global MainActor default without having to nonisolate an
/// entire extension.
nonisolated private func stripPrefix(_ prefix: String, from line: String) -> String? {
  guard line.hasPrefix(prefix) else { return nil }
  return String(line.dropFirst(prefix.count))
}
