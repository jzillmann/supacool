import ComposableArchitecture
import Foundation

struct GitClientDependency: Sendable {
  var repoRoot: @Sendable (URL) async throws -> URL
  var worktrees: @Sendable (URL) async throws -> [Worktree]
  var pruneWorktrees: @Sendable (URL) async throws -> Void
  var localBranchNames: @Sendable (URL) async throws -> Set<String>
  var isValidBranchName: @Sendable (String, URL) async -> Bool
  var branchRefs: @Sendable (URL) async throws -> [String]
  var defaultRemoteBranchRef: @Sendable (URL) async throws -> String?
  var automaticWorktreeBaseRef: @Sendable (URL) async -> String?
  var ignoredFileCount: @Sendable (URL) async throws -> Int
  var untrackedFileCount: @Sendable (URL) async throws -> Int
  var createWorktree:
    @Sendable (
      _ name: String,
      _ repoRoot: URL,
      _ baseDirectory: URL,
      _ copyIgnored: Bool,
      _ copyUntracked: Bool,
      _ baseRef: String
    ) async throws
      -> Worktree
  var createWorktreeStream:
    @Sendable (
      _ name: String,
      _ repoRoot: URL,
      _ baseDirectory: URL,
      _ copyIgnored: Bool,
      _ copyUntracked: Bool,
      _ baseRef: String
    ) -> AsyncThrowingStream<GitWorktreeCreateEvent, Error>
  var removeWorktree: @Sendable (_ worktree: Worktree, _ deleteBranch: Bool) async throws -> URL
  var isBareRepository: @Sendable (_ repoRoot: URL) async throws -> Bool
  var branchName: @Sendable (URL) async -> String?
  var lineChanges: @Sendable (URL) async -> (added: Int, removed: Int)?
  var renameBranch: @Sendable (_ worktreeURL: URL, _ branchName: String) async throws -> Void
  var remoteNames: @Sendable (_ repoRoot: URL) async throws -> [String]
  var fetchRemote: @Sendable (_ remote: String, _ repoRoot: URL) async throws -> Void
  var remoteInfo: @Sendable (_ repositoryRoot: URL) async -> GithubRemoteInfo?
  /// `git status --porcelain=v1 -z` output for the worktree. The `-z`
  /// byte-delimiter keeps paths with spaces / newlines intact — callers
  /// split on `\0`.
  var statusPorcelain: @Sendable (_ worktreeURL: URL) async throws -> String
  /// Full diff for a single path. `cached == true` yields
  /// `git diff --cached`, else working-tree vs. HEAD.
  var diffForFile:
    @Sendable (_ worktreeURL: URL, _ path: String, _ cached: Bool) async throws -> String
  /// Three-dot diff (merge-base relative) of a single path between
  /// `baseRef` and HEAD. Used by the QuickDiffSheet's "vs. base" mode.
  var diffForFileAgainstBase:
    @Sendable (_ worktreeURL: URL, _ path: String, _ baseRef: String) async throws -> String
  /// Changed files between `baseRef` and HEAD (three-dot). Returns the
  /// list with per-file status + line counts already populated.
  var changedFilesAgainst:
    @Sendable (_ baseRef: String, _ worktreeURL: URL) async throws -> [ChangedFile]
  /// Per-file added/removed counts via `git diff HEAD --numstat`.
  /// Returns `nil` for binary files or unparseable output.
  var numstatForFile:
    @Sendable (_ worktreeURL: URL, _ path: String) async -> (added: Int, removed: Int)?
}

extension GitClientDependency: DependencyKey {
  static let liveValue = GitClientDependency(
    repoRoot: { try await GitClient().repoRoot(for: $0) },
    worktrees: { try await GitClient().worktrees(for: $0) },
    pruneWorktrees: { try await GitClient().pruneWorktrees(for: $0) },
    localBranchNames: { try await GitClient().localBranchNames(for: $0) },
    isValidBranchName: { branchName, repoRoot in
      await GitClient().isValidBranchName(branchName, for: repoRoot)
    },
    branchRefs: { try await GitClient().branchRefs(for: $0) },
    defaultRemoteBranchRef: { try await GitClient().defaultRemoteBranchRef(for: $0) },
    automaticWorktreeBaseRef: { await GitClient().automaticWorktreeBaseRef(for: $0) },
    ignoredFileCount: { try await GitClient().ignoredFileCount(for: $0) },
    untrackedFileCount: { try await GitClient().untrackedFileCount(for: $0) },
    createWorktree: { name, repoRoot, baseDirectory, copyIgnored, copyUntracked, baseRef in
      try await GitClient().createWorktree(
        named: name,
        in: repoRoot,
        baseDirectory: baseDirectory,
        copyFiles: (ignored: copyIgnored, untracked: copyUntracked),
        baseRef: baseRef
      )
    },
    createWorktreeStream: { name, repoRoot, baseDirectory, copyIgnored, copyUntracked, baseRef in
      GitClient().createWorktreeStream(
        named: name,
        in: repoRoot,
        baseDirectory: baseDirectory,
        copyFiles: (ignored: copyIgnored, untracked: copyUntracked),
        baseRef: baseRef
      )
    },
    removeWorktree: { worktree, deleteBranch in
      try await GitClient().removeWorktree(worktree, deleteBranch: deleteBranch)
    },
    isBareRepository: { repoRoot in
      try await GitClient().isBareRepository(for: repoRoot)
    },
    branchName: { await GitClient().branchName(for: $0) },
    lineChanges: { await GitClient().lineChanges(at: $0) },
    renameBranch: { worktreeURL, branchName in
      try await GitClient().renameBranch(in: worktreeURL, to: branchName)
    },
    remoteNames: { try await GitClient().remoteNames(for: $0) },
    fetchRemote: { remote, repoRoot in try await GitClient().fetchRemote(remote, for: repoRoot) },
    remoteInfo: { repositoryRoot in
      await GitClient().remoteInfo(for: repositoryRoot)
    },
    statusPorcelain: { try await GitClient().statusPorcelain(at: $0) },
    diffForFile: { worktreeURL, path, cached in
      try await GitClient().diffForFile(at: worktreeURL, path: path, cached: cached)
    },
    diffForFileAgainstBase: { worktreeURL, path, baseRef in
      try await GitClient().diffForFile(at: worktreeURL, path: path, baseRef: baseRef)
    },
    changedFilesAgainst: { baseRef, worktreeURL in
      try await GitClient().changedFilesAgainst(baseRef: baseRef, at: worktreeURL)
    },
    numstatForFile: { worktreeURL, path in
      await GitClient().numstatForFile(at: worktreeURL, path: path)
    }
  )
  static let testValue = liveValue
}

extension DependencyValues {
  var gitClient: GitClientDependency {
    get { self[GitClientDependency.self] }
    set { self[GitClientDependency.self] = newValue }
  }
}
