import Foundation

/// A repository-specific remote launch target. Unlike `RemoteWorkspace`,
/// this hangs off a local repository's settings so New Terminal can ask
/// "local or remote?" for the same project.
nonisolated struct RepositoryRemoteTarget: Identifiable, Hashable, Codable, Sendable {
  let id: UUID
  let hostID: RemoteHost.ID
  var remoteWorkingDirectory: String
  var displayName: String

  init(
    id: UUID = UUID(),
    hostID: RemoteHost.ID,
    remoteWorkingDirectory: String,
    displayName: String? = nil
  ) {
    self.id = id
    self.hostID = hostID
    self.remoteWorkingDirectory = remoteWorkingDirectory
    self.displayName = displayName ?? Self.deriveDisplayName(from: remoteWorkingDirectory)
  }

  enum CodingKeys: String, CodingKey {
    case id, hostID, remoteWorkingDirectory, displayName
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(UUID.self, forKey: .id)
    hostID = try c.decode(UUID.self, forKey: .hostID)
    remoteWorkingDirectory = try c.decode(String.self, forKey: .remoteWorkingDirectory)
    displayName =
      try c.decodeIfPresent(String.self, forKey: .displayName)
      ?? Self.deriveDisplayName(from: remoteWorkingDirectory)
  }

  nonisolated static func deriveDisplayName(from path: String) -> String {
    let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/ \t\n"))
    if trimmed.isEmpty { return path }
    if let slash = trimmed.lastIndex(of: "/") {
      return String(trimmed[trimmed.index(after: slash)...])
    }
    return trimmed
  }
}
