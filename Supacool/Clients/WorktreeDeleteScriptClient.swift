import ComposableArchitecture
import Foundation

/// Runs a repository's `deleteScript` for a worktree that is about to be
/// removed, on the teardown paths that have no terminal tab to host a
/// blocking script run.
///
/// The user-facing delete flow (`RepositoriesFeature.deleteWorktreeConfirmed`)
/// runs that script as a *blocking* script in a visible tab, so the user can
/// watch it and answer an alert if it fails. Two other paths remove worktrees
/// without ever reaching it — the Worktree Janitor's orphan sweep and the
/// cleanup after a failed worktree creation — and used to call
/// `gitClient.removeWorktree` directly. For a repo whose delete script does
/// real teardown (stopping services, dropping a per-worktree database) that
/// silently leaked those resources: the directory went away and nothing else
/// did. This client closes that gap by running the same script headlessly.
///
/// A batch sweep must not open one terminal tab per orphan, which is why this
/// is a headless runner rather than a reuse of the blocking-script machinery.
nonisolated struct WorktreeDeleteScriptClient: Sendable {
  var run: @Sendable (
    Worktree,
    String,
    ServerLifecycleScriptContext
  ) async throws -> ServerLifecycleScriptResult
}

extension WorktreeDeleteScriptClient: DependencyKey {
  static let liveValue = WorktreeDeleteScriptClient { worktree, script, context in
    try await runWorktreeScript(
      worktree: worktree,
      kindRawValue: "delete",
      script: script,
      context: context
    )
  }

  static let testValue = WorktreeDeleteScriptClient { _, _, _ in
    ServerLifecycleScriptResult(exitCode: 0, stdout: "", stderr: "")
  }
}

extension WorktreeDeleteScriptClient {
  /// `event` values passed to the script as `$SUPACOOL_EVENT`, so a repo's
  /// delete script can tell which teardown path invoked it.
  enum Event: String, Sendable {
    /// Worktree Janitor orphan sweep.
    case janitorSweep = "janitor_sweep"
    /// Cleanup after a worktree creation that failed part-way.
    case creationFailed = "creation_failed"
  }
}
