import Foundation

nonisolated enum SupacoolPaths {
  /// Explicit data-directory override, resolved once per process. Set by
  /// the isolated-preview launcher as a LAUNCH ARGUMENT
  /// (`-SupacoolDataDirectory <path>`), which UserDefaults surfaces via
  /// the argument domain.
  ///
  /// Why not the `$HOME` redirect the preview script used to rely on:
  /// Foundation's `homeDirectoryForCurrentUser` resolves the account
  /// record and IGNORES the `HOME` environment variable — so "isolated"
  /// previews silently pointed at the real `~/.supacool` and were then
  /// (correctly) blocked by `SingleInstanceGuard`. An argv-based override
  /// actually takes effect, and — unlike an env var — is invisible to
  /// child shells, so a real Supacool launched from inside a preview
  /// terminal can't accidentally inherit the sandbox.
  private static let dataDirectoryOverride: URL? = {
    guard let raw = UserDefaults.standard.string(forKey: "SupacoolDataDirectory"),
      !raw.isEmpty
    else { return nil }
    return URL(
      filePath: NSString(string: raw).expandingTildeInPath,
      directoryHint: .isDirectory
    ).standardizedFileURL
  }()

  static var baseDirectory: URL {
    dataDirectoryOverride
      ?? FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".supacool", directoryHint: .isDirectory)
  }

  /// The home directory processes SPAWNED BY THIS APP will see: the
  /// `HOME` environment variable when set (every PTY we create inherits
  /// it), falling back to the account record. Use this for anything an
  /// agent or shell reads/writes under `~` — hook settings, `~/.claude`
  /// state, terminfo — so the app and its children agree on the same
  /// files. In normal launches this equals `homeDirectoryForCurrentUser`;
  /// in isolated previews the launcher redirects `HOME` to the sandbox,
  /// and installing hooks into the real `~/.claude` while the spawned
  /// claude reads the sandbox one silently breaks all busy/session-id
  /// tracking (no adoption, no resume — observed 2026-07-28).
  static var spawnedProcessHomeDirectory: URL {
    if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty {
      return URL(filePath: home, directoryHint: .isDirectory).standardizedFileURL
    }
    return FileManager.default.homeDirectoryForCurrentUser
  }

  static var reposDirectory: URL {
    baseDirectory.appending(path: "repos", directoryHint: .isDirectory)
  }

  /// One folder per board session: `~/.supacool/sessions/<id>/session.json`.
  /// Replaces the single global `agent-sessions.json` so a bad write or a
  /// decode failure damages one session instead of wiping the whole board.
  /// See `SessionDirectoryStore`.
  static var sessionsDirectory: URL {
    baseDirectory.appending(path: "sessions", directoryHint: .isDirectory)
  }

  /// Local directory ssh's `ControlMaster` binds its multiplex socket
  /// inside (`-o ControlPath=~/.supacool/ssh/%r@%h:%p`). ssh expands the
  /// tilde locally but does NOT create the parent — first spawn on a
  /// clean machine fails with `unix_listener: cannot bind to path` if
  /// this directory is missing.
  static var sshControlDirectory: URL {
    baseDirectory.appending(path: "ssh", directoryHint: .isDirectory)
  }

  /// Idempotent mkdir-p for `sshControlDirectory`. Call at every site
  /// that hands ssh / scp the ControlPath option — `createDirectory` is
  /// a no-op when the directory already exists.
  static func ensureSSHControlDirectoryExists() throws {
    try FileManager.default.createDirectory(
      at: sshControlDirectory,
      withIntermediateDirectories: true,
      attributes: nil
    )
  }

  static func repositoryDirectory(for rootURL: URL) -> URL {
    let name = repositoryDirectoryName(for: rootURL)
    return reposDirectory.appending(path: name, directoryHint: .isDirectory)
  }

  static func normalizedWorktreeBaseDirectoryPath(
    _ rawPath: String?,
    repositoryRootURL: URL? = nil
  ) -> String? {
    guard let rawPath else {
      return nil
    }
    let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return nil
    }
    let expanded = NSString(string: trimmed).expandingTildeInPath
    let directoryURL: URL
    if expanded.hasPrefix("/") {
      directoryURL = URL(filePath: expanded, directoryHint: .isDirectory)
    } else if let repositoryRootURL {
      directoryURL = repositoryRootURL.standardizedFileURL
        .appending(path: expanded, directoryHint: .isDirectory)
    } else {
      directoryURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: expanded, directoryHint: .isDirectory)
    }
    return directoryURL.standardizedFileURL.path(percentEncoded: false)
  }

  static func worktreeBaseDirectory(
    for repositoryRootURL: URL,
    globalDefaultPath: String?,
    repositoryOverridePath: String?
  ) -> URL {
    let rootURL = repositoryRootURL.standardizedFileURL
    if let repositoryOverridePath = normalizedWorktreeBaseDirectoryPath(
      repositoryOverridePath,
      repositoryRootURL: rootURL
    ) {
      return URL(filePath: repositoryOverridePath, directoryHint: .isDirectory).standardizedFileURL
    }
    if let globalDefaultPath = normalizedWorktreeBaseDirectoryPath(globalDefaultPath) {
      return URL(filePath: globalDefaultPath, directoryHint: .isDirectory)
        .standardizedFileURL
        .appending(path: repositoryDirectoryName(for: rootURL), directoryHint: .isDirectory)
        .standardizedFileURL
    }
    return repositoryDirectory(for: rootURL)
  }

  static func exampleWorktreePath(
    for repositoryRootURL: URL,
    globalDefaultPath: String?,
    repositoryOverridePath: String?,
    branchName: String = "swift-otter"
  ) -> String {
    worktreeBaseDirectory(
      for: repositoryRootURL,
      globalDefaultPath: globalDefaultPath,
      repositoryOverridePath: repositoryOverridePath
    )
    .appending(path: branchName, directoryHint: .isDirectory)
    .standardizedFileURL
    .path(percentEncoded: false)
  }

  static var layoutsURL: URL {
    baseDirectory.appending(path: "layouts.json", directoryHint: .notDirectory)
  }

  static var settingsURL: URL {
    baseDirectory.appending(path: "settings.json", directoryHint: .notDirectory)
  }

  static func repositorySettingsURL(for rootURL: URL) -> URL {
    rootURL.standardizedFileURL.appending(path: "supacool.json", directoryHint: .notDirectory)
  }

  private static func repositoryDirectoryName(for rootURL: URL) -> String {
    let repoName = rootURL.lastPathComponent
    if repoName.isEmpty || repoName == ".bare" || repoName == ".git" {
      let path = rootURL.standardizedFileURL.path(percentEncoded: false)
      let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      if trimmed.isEmpty {
        return "_"
      }
      return trimmed.replacing("/", with: "_")
    }
    return repoName
  }
}
