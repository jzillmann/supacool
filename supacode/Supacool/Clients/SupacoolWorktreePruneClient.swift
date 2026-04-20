import ComposableArchitecture
import Foundation

private nonisolated let pruneClientLogger = SupaLogger("Supacool.WorktreePrune")

/// Supacool-owned wrapper around `git worktree prune --verbose` that
/// returns the list of pruned worktree refs so the UI can tell the user
/// how many entries were cleaned up (the upstream
/// `GitClient.pruneWorktrees` is silent).
///
/// Kept under `supacode/Supacool/` so upstream syncs stay conflict-free.
struct SupacoolWorktreePruneClient: Sendable {
  var prune: @Sendable (_ repoRoot: URL) async throws -> SupacoolPruneResult
}

nonisolated struct SupacoolPruneResult: Equatable, Sendable {
  /// Worktree short-names parsed from git's "Removing worktrees/<name>:"
  /// lines. Empty when git found nothing to prune.
  let prunedRefs: [String]
  /// Raw stdout+stderr for diagnostics. Not rendered in the UI but kept
  /// for logging / future error surfacing.
  let rawOutput: String
}

extension SupacoolWorktreePruneClient: DependencyKey {
  static let liveValue = live()

  static func live(shell: ShellClient = .liveValue) -> SupacoolWorktreePruneClient {
    SupacoolWorktreePruneClient(
      prune: { repoRoot in
        let envURL = URL(fileURLWithPath: "/usr/bin/env")
        let args = ["git", "-C", repoRoot.path(percentEncoded: false), "worktree", "prune", "--verbose"]
        let output: ShellOutput
        do {
          output = try await shell.runLogin(envURL, args, nil, log: false)
        } catch {
          pruneClientLogger.warning(
            "git worktree prune failed in \(repoRoot.path(percentEncoded: false)): "
              + "\(error.localizedDescription)"
          )
          throw error
        }
        // `git worktree prune --verbose` writes "Removing worktrees/<name>:
        // <reason>" lines to stderr (not stdout) in modern git. Merge
        // both streams so the parser doesn't care which stream git
        // picked.
        let merged = [output.stdout, output.stderr]
          .filter { !$0.isEmpty }
          .joined(separator: "\n")
        return SupacoolPruneResult(
          prunedRefs: parsePrunedRefs(from: merged),
          rawOutput: merged
        )
      }
    )
  }

  static let testValue = SupacoolWorktreePruneClient(
    prune: { _ in
      struct UnimplementedPrune: Error {}
      throw UnimplementedPrune()
    }
  )
}

extension DependencyValues {
  var supacoolWorktreePrune: SupacoolWorktreePruneClient {
    get { self[SupacoolWorktreePruneClient.self] }
    set { self[SupacoolWorktreePruneClient.self] = newValue }
  }
}

// MARK: - Parsing

/// Parse the worktree names out of `git worktree prune --verbose` output.
/// Each pruned ref produces one line like:
///     Removing worktrees/feature-x: gitdir file points to non-existent location
/// We only care about the `<name>` slice between `Removing worktrees/`
/// and the colon. Lines that don't match are ignored silently.
nonisolated func parsePrunedRefs(from output: String) -> [String] {
  let pattern = /Removing worktrees\/([^:\n]+):/
  return
    output
    .matches(of: pattern)
    .map { String($0.output.1).trimmingCharacters(in: .whitespaces) }
    .filter { !$0.isEmpty }
}
