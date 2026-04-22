import ComposableArchitecture
import Foundation

private nonisolated let repoSyncLogger = SupaLogger("Supacool.RepoSync")

/// Supacool-owned "keep the repo root fresh" helper.
///
/// Exists because Supacool's model is that users don't do work in the
/// repo root — they work in worktrees. The root should be a read-only
/// reference copy that sits on the default branch at origin/HEAD. This
/// client implements the "fast-forward it to origin/main if it's safe"
/// dance, with conservative guards so we never surprise the user.
///
/// Guards (any failure → skip the sync silently):
/// - HEAD must be the repo's default branch (`git symbolic-ref
///   refs/remotes/origin/HEAD` → e.g. `refs/remotes/origin/main`).
/// - Working tree must be clean (`git status --porcelain`).
/// - Fetch must succeed (we don't attempt a merge against stale refs).
/// - Merge must be strict fast-forward (`--ff-only`) — never auto-merge
///   or rebase anything.
///
/// Kept under `supacode/Supacool/` so upstream syncs stay conflict-free.
nonisolated struct RepoSyncClient: Sendable {
  /// Try to fast-forward the repo root to its default origin branch.
  /// Never mutates state unless every guard passes. Returns a structured
  /// outcome the caller can log or surface in UI.
  var syncIfSafe: @Sendable (_ repoRoot: URL) async -> RepoSyncOutcome
}

/// Structured result of a sync attempt. `.synced(ahead: 0)` means the
/// repo was already up-to-date; `.synced(ahead: N)` means we advanced
/// HEAD by N commits. Every `.skipped` variant carries the reason so
/// the caller can decide whether to surface it.
nonisolated enum RepoSyncOutcome: Equatable, Sendable {
  case synced(advancedBy: Int)
  case skippedDirtyTree
  case skippedNotOnDefaultBranch(currentBranch: String, defaultBranch: String)
  case skippedNoDefaultBranch  // origin/HEAD not resolvable
  case skippedFetchFailed(message: String)
  case skippedFastForwardNotPossible(message: String)
  case failedUnknown(message: String)

  var isSuccess: Bool {
    if case .synced = self { return true }
    return false
  }
}

extension RepoSyncClient: DependencyKey {
  static let liveValue = live()

  static func live(shell: ShellClient = .liveValue) -> RepoSyncClient {
    RepoSyncClient(
      syncIfSafe: { repoRoot in
        do {
          return try await performSync(repoRoot: repoRoot, shell: shell)
        } catch {
          repoSyncLogger.warning(
            "RepoSyncClient failed for \(repoRoot.path(percentEncoded: false)): \(error.localizedDescription)"
          )
          return .failedUnknown(message: error.localizedDescription)
        }
      }
    )
  }

  static let testValue = RepoSyncClient(
    syncIfSafe: { _ in
      struct UnimplementedSync: Error {}
      return .failedUnknown(message: "\(UnimplementedSync())")
    }
  )
}

extension DependencyValues {
  var repoSync: RepoSyncClient {
    get { self[RepoSyncClient.self] }
    set { self[RepoSyncClient.self] = newValue }
  }
}

// MARK: - Live implementation

/// Runs the guard chain + sync. Splits cleanly so unit tests can
/// exercise the decision logic by stubbing a `ShellClient` with scripted
/// outputs (see `RepoSyncClientTests`).
nonisolated private func performSync(
  repoRoot: URL,
  shell: ShellClient
) async throws -> RepoSyncOutcome {
  let repoPath = repoRoot.path(percentEncoded: false)
  let env = URL(fileURLWithPath: "/usr/bin/env")

  // 1. Resolve the default branch via origin/HEAD. If origin/HEAD isn't
  //    set (fresh clone missing the symref, weird CI setup), we have no
  //    authoritative target to sync to and give up silently.
  let defaultRef: String
  do {
    let out = try await shell.run(
      env,
      ["git", "-C", repoPath, "symbolic-ref", "--short", "refs/remotes/origin/HEAD"],
      nil
    )
    defaultRef = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  } catch {
    return .skippedNoDefaultBranch
  }
  guard !defaultRef.isEmpty else { return .skippedNoDefaultBranch }
  // `symbolic-ref --short` returns e.g. `origin/main` — strip the remote
  // prefix so we can compare against local branch name below.
  let defaultBranch = defaultRef.hasPrefix("origin/")
    ? String(defaultRef.dropFirst("origin/".count))
    : defaultRef

  // 2. Current branch. Detached HEAD → empty string → counts as
  //    "not on default" (conservative: investigating a specific commit
  //    is a legit workflow, don't touch it).
  let currentBranch: String
  do {
    let out = try await shell.run(
      env,
      ["git", "-C", repoPath, "rev-parse", "--abbrev-ref", "HEAD"],
      nil
    )
    currentBranch = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  } catch {
    return .failedUnknown(message: error.localizedDescription)
  }
  guard currentBranch == defaultBranch else {
    return .skippedNotOnDefaultBranch(
      currentBranch: currentBranch.isEmpty ? "<detached>" : currentBranch,
      defaultBranch: defaultBranch
    )
  }

  // 3. Clean working tree. `status --porcelain` prints one line per
  //    change; empty output means clean.
  do {
    let out = try await shell.run(
      env,
      ["git", "-C", repoPath, "status", "--porcelain"],
      nil
    )
    let trimmed = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty else { return .skippedDirtyTree }
  } catch {
    return .failedUnknown(message: error.localizedDescription)
  }

  // Pre-fetch SHA of HEAD and upstream so we can report `advancedBy`.
  let headBefore = (try? await shell.run(
    env, ["git", "-C", repoPath, "rev-parse", "HEAD"], nil
  ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""

  // 4. Fetch origin. Any error here → stop (we won't merge against
  //    stale refs just to show "up-to-date" when we're actually not).
  do {
    _ = try await shell.run(
      env,
      ["git", "-C", repoPath, "fetch", "origin", defaultBranch],
      nil
    )
  } catch let error as ShellClientError {
    return .skippedFetchFailed(message: error.localizedDescription)
  } catch {
    return .skippedFetchFailed(message: error.localizedDescription)
  }

  // 5. Fast-forward merge. `--ff-only` refuses to auto-merge; if
  //    we've diverged (rare on a read-only root, but possible if
  //    someone committed locally), we bail without touching state.
  do {
    _ = try await shell.run(
      env,
      ["git", "-C", repoPath, "merge", "--ff-only", "origin/\(defaultBranch)"],
      nil
    )
  } catch {
    return .skippedFastForwardNotPossible(message: error.localizedDescription)
  }

  let headAfter = (try? await shell.run(
    env, ["git", "-C", repoPath, "rev-parse", "HEAD"], nil
  ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""

  let advancedBy: Int
  if headBefore == headAfter || headBefore.isEmpty || headAfter.isEmpty {
    advancedBy = 0
  } else {
    // Count commits between the two SHAs. Cheap and exact.
    advancedBy =
      (try? await shell.run(
        env,
        ["git", "-C", repoPath, "rev-list", "--count", "\(headBefore)..\(headAfter)"],
        nil
      ).stdout.trimmingCharacters(in: .whitespacesAndNewlines))
      .flatMap(Int.init) ?? 0
  }

  return .synced(advancedBy: advancedBy)
}
