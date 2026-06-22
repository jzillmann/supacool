import Foundation

nonisolated struct ServerLifecycleSettings: Codable, Equatable, Sendable {
  var name: String
  var statusScript: String
  var startScript: String
  var stopScript: String
  var autoStopOnSessionRemove: Bool
  var autoStopOnPark: Bool
  var autoStartOnUnpark: Bool

  private enum CodingKeys: String, CodingKey {
    case name
    case statusScript
    case startScript
    case stopScript
    case autoStopOnSessionRemove
    case autoStopOnPark
    case autoStartOnUnpark
  }

  static let `default` = ServerLifecycleSettings(
    name: "Dev server",
    statusScript: "",
    startScript: "",
    stopScript: "",
    autoStopOnSessionRemove: true,
    autoStopOnPark: true,
    autoStartOnUnpark: false
  )

  var isConfigured: Bool {
    !statusScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !startScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !stopScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  init(
    name: String,
    statusScript: String,
    startScript: String,
    stopScript: String,
    autoStopOnSessionRemove: Bool,
    autoStopOnPark: Bool,
    autoStartOnUnpark: Bool
  ) {
    self.name = name
    self.statusScript = statusScript
    self.startScript = startScript
    self.stopScript = stopScript
    self.autoStopOnSessionRemove = autoStopOnSessionRemove
    self.autoStopOnPark = autoStopOnPark
    self.autoStartOnUnpark = autoStartOnUnpark
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    name = try container.decodeIfPresent(String.self, forKey: .name) ?? Self.default.name
    statusScript =
      try container.decodeIfPresent(String.self, forKey: .statusScript) ?? Self.default.statusScript
    startScript =
      try container.decodeIfPresent(String.self, forKey: .startScript) ?? Self.default.startScript
    stopScript =
      try container.decodeIfPresent(String.self, forKey: .stopScript) ?? Self.default.stopScript
    autoStopOnSessionRemove =
      try container.decodeIfPresent(Bool.self, forKey: .autoStopOnSessionRemove)
      ?? Self.default.autoStopOnSessionRemove
    autoStopOnPark =
      try container.decodeIfPresent(Bool.self, forKey: .autoStopOnPark) ?? Self.default.autoStopOnPark
    autoStartOnUnpark =
      try container.decodeIfPresent(Bool.self, forKey: .autoStartOnUnpark) ?? Self.default.autoStartOnUnpark
  }
}

nonisolated struct RepositorySettings: Codable, Equatable, Sendable {
  var setupScript: String
  var archiveScript: String
  var deleteScript: String
  var runScript: String
  var serverLifecycle: ServerLifecycleSettings
  var openActionID: String
  var remoteTargets: [RepositoryRemoteTarget]
  var worktreeBaseRef: String?
  var worktreeBaseDirectoryPath: String?
  var copyIgnoredOnWorktreeCreate: Bool?
  var copyUntrackedOnWorktreeCreate: Bool?
  var pullRequestMergeStrategy: PullRequestMergeStrategy?
  /// Comma-separated Linear team keys for this repo (e.g. `CEN, FOO`). Used
  /// as the server-side scope when the Linear Inbox imports recently created
  /// tickets — see `LinearInboxFeature`. Nil/empty means this repo
  /// contributes no scope to the (global) inbox import.
  var linearTeamKeys: String?
  /// When true, Claude Code sessions for this repo launch with
  /// `--add-dir <worktrees parent>` so the agent can roam across sibling
  /// worktrees without Claude snapping the shell cwd back to the launch
  /// dir. Off by default — it widens the session's file access to every
  /// worktree of this repository. Only Claude exposes the flag; Codex and
  /// Pi silently ignore the request.
  var allowCrossWorktreeAccess: Bool

  private enum CodingKeys: String, CodingKey {
    case setupScript
    case archiveScript
    case deleteScript
    case runScript
    case serverLifecycle
    case openActionID
    case remoteTargets
    case worktreeBaseRef
    case worktreeBaseDirectoryPath
    case copyIgnoredOnWorktreeCreate
    case copyUntrackedOnWorktreeCreate
    case pullRequestMergeStrategy
    case linearTeamKeys
    case allowCrossWorktreeAccess
  }

  static let `default` = RepositorySettings(
    setupScript: "",
    archiveScript: "",
    deleteScript: "",
    runScript: "",
    serverLifecycle: .default,
    openActionID: OpenWorktreeAction.automaticSettingsID,
    remoteTargets: [],
    worktreeBaseRef: nil,
    worktreeBaseDirectoryPath: nil,
    copyIgnoredOnWorktreeCreate: nil,
    copyUntrackedOnWorktreeCreate: nil,
    pullRequestMergeStrategy: nil,
    linearTeamKeys: nil,
    allowCrossWorktreeAccess: false
  )

  init(
    setupScript: String,
    archiveScript: String,
    deleteScript: String,
    runScript: String,
    serverLifecycle: ServerLifecycleSettings = .default,
    openActionID: String,
    remoteTargets: [RepositoryRemoteTarget] = [],
    worktreeBaseRef: String?,
    worktreeBaseDirectoryPath: String? = nil,
    copyIgnoredOnWorktreeCreate: Bool? = nil,
    copyUntrackedOnWorktreeCreate: Bool? = nil,
    pullRequestMergeStrategy: PullRequestMergeStrategy? = nil,
    linearTeamKeys: String? = nil,
    allowCrossWorktreeAccess: Bool = false
  ) {
    self.setupScript = setupScript
    self.archiveScript = archiveScript
    self.deleteScript = deleteScript
    self.runScript = runScript
    self.serverLifecycle = serverLifecycle
    self.openActionID = openActionID
    self.remoteTargets = remoteTargets
    self.worktreeBaseRef = worktreeBaseRef
    self.worktreeBaseDirectoryPath = worktreeBaseDirectoryPath
    self.copyIgnoredOnWorktreeCreate = copyIgnoredOnWorktreeCreate
    self.copyUntrackedOnWorktreeCreate = copyUntrackedOnWorktreeCreate
    self.pullRequestMergeStrategy = pullRequestMergeStrategy
    self.linearTeamKeys = linearTeamKeys
    self.allowCrossWorktreeAccess = allowCrossWorktreeAccess
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    setupScript =
      try container.decodeIfPresent(String.self, forKey: .setupScript)
      ?? Self.default.setupScript
    archiveScript =
      try container.decodeIfPresent(String.self, forKey: .archiveScript)
      ?? Self.default.archiveScript
    deleteScript =
      try container.decodeIfPresent(String.self, forKey: .deleteScript)
      ?? Self.default.deleteScript
    runScript =
      try container.decodeIfPresent(String.self, forKey: .runScript)
      ?? Self.default.runScript
    serverLifecycle =
      try container.decodeIfPresent(ServerLifecycleSettings.self, forKey: .serverLifecycle)
      ?? Self.default.serverLifecycle
    openActionID =
      try container.decodeIfPresent(String.self, forKey: .openActionID)
      ?? Self.default.openActionID
    remoteTargets =
      try container.decodeIfPresent([RepositoryRemoteTarget].self, forKey: .remoteTargets)
      ?? Self.default.remoteTargets
    worktreeBaseRef =
      try container.decodeIfPresent(String.self, forKey: .worktreeBaseRef)
    worktreeBaseDirectoryPath =
      try container.decodeIfPresent(String.self, forKey: .worktreeBaseDirectoryPath)
    copyIgnoredOnWorktreeCreate =
      try container.decodeIfPresent(Bool.self, forKey: .copyIgnoredOnWorktreeCreate)
      ?? Self.default.copyIgnoredOnWorktreeCreate
    copyUntrackedOnWorktreeCreate =
      try container.decodeIfPresent(Bool.self, forKey: .copyUntrackedOnWorktreeCreate)
      ?? Self.default.copyUntrackedOnWorktreeCreate
    pullRequestMergeStrategy =
      try container.decodeIfPresent(PullRequestMergeStrategy.self, forKey: .pullRequestMergeStrategy)
      ?? Self.default.pullRequestMergeStrategy
    linearTeamKeys =
      try container.decodeIfPresent(String.self, forKey: .linearTeamKeys)
    allowCrossWorktreeAccess =
      try container.decodeIfPresent(Bool.self, forKey: .allowCrossWorktreeAccess)
      ?? Self.default.allowCrossWorktreeAccess
  }
}
