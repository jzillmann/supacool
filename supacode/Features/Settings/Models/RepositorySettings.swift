import Foundation

nonisolated struct RepositorySettings: Codable, Equatable, Sendable {
  var setupScript: String
  var archiveScript: String
  var deleteScript: String
  var runScript: String
  var openActionID: String
  var remoteTargets: [RepositoryRemoteTarget]
  var worktreeBaseRef: String?
  var worktreeBaseDirectoryPath: String?
  var copyIgnoredOnWorktreeCreate: Bool?
  var copyUntrackedOnWorktreeCreate: Bool?
  var pullRequestMergeStrategy: PullRequestMergeStrategy?

  private enum CodingKeys: String, CodingKey {
    case setupScript
    case archiveScript
    case deleteScript
    case runScript
    case openActionID
    case remoteTargets
    case worktreeBaseRef
    case worktreeBaseDirectoryPath
    case copyIgnoredOnWorktreeCreate
    case copyUntrackedOnWorktreeCreate
    case pullRequestMergeStrategy
  }

  static let `default` = RepositorySettings(
    setupScript: "",
    archiveScript: "",
    deleteScript: "",
    runScript: "",
    openActionID: OpenWorktreeAction.automaticSettingsID,
    remoteTargets: [],
    worktreeBaseRef: nil,
    worktreeBaseDirectoryPath: nil,
    copyIgnoredOnWorktreeCreate: nil,
    copyUntrackedOnWorktreeCreate: nil,
    pullRequestMergeStrategy: nil
  )

  init(
    setupScript: String,
    archiveScript: String,
    deleteScript: String,
    runScript: String,
    openActionID: String,
    remoteTargets: [RepositoryRemoteTarget] = [],
    worktreeBaseRef: String?,
    worktreeBaseDirectoryPath: String? = nil,
    copyIgnoredOnWorktreeCreate: Bool? = nil,
    copyUntrackedOnWorktreeCreate: Bool? = nil,
    pullRequestMergeStrategy: PullRequestMergeStrategy? = nil
  ) {
    self.setupScript = setupScript
    self.archiveScript = archiveScript
    self.deleteScript = deleteScript
    self.runScript = runScript
    self.openActionID = openActionID
    self.remoteTargets = remoteTargets
    self.worktreeBaseRef = worktreeBaseRef
    self.worktreeBaseDirectoryPath = worktreeBaseDirectoryPath
    self.copyIgnoredOnWorktreeCreate = copyIgnoredOnWorktreeCreate
    self.copyUntrackedOnWorktreeCreate = copyUntrackedOnWorktreeCreate
    self.pullRequestMergeStrategy = pullRequestMergeStrategy
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
  }
}
