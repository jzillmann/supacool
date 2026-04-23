import Foundation

/// A named working directory on a remote host — the remote analog of a
/// local `Worktree`. Each entry points at one absolute path on one host;
/// sessions spawn their tmux into that directory.
nonisolated struct RemoteWorkspace: Identifiable, Hashable, Codable, Sendable {
  let id: UUID
  let hostID: RemoteHost.ID
  /// Absolute path on the remote host. No expansion — we pass it verbatim
  /// to `tmux new-session -c` and let the remote shell handle it.
  var remoteWorkingDirectory: String
  var displayName: String
  let createdAt: Date

  init(
    id: UUID = UUID(),
    hostID: RemoteHost.ID,
    remoteWorkingDirectory: String,
    displayName: String? = nil,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.hostID = hostID
    self.remoteWorkingDirectory = remoteWorkingDirectory
    self.displayName = displayName ?? Self.deriveDisplayName(from: remoteWorkingDirectory)
    self.createdAt = createdAt
  }

  // Forward-compatible Codable — see docs/agent-guides/persistence.md.
  enum CodingKeys: String, CodingKey {
    case id, hostID, remoteWorkingDirectory, displayName, createdAt
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(UUID.self, forKey: .id)
    hostID = try c.decode(UUID.self, forKey: .hostID)
    remoteWorkingDirectory = try c.decode(String.self, forKey: .remoteWorkingDirectory)
    displayName =
      try c.decodeIfPresent(String.self, forKey: .displayName)
      ?? Self.deriveDisplayName(from: remoteWorkingDirectory)
    createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
  }

  /// Last path component, or the full path if there is no `/`.
  nonisolated static func deriveDisplayName(from path: String) -> String {
    let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/ \t\n"))
    if trimmed.isEmpty { return path }
    if let slash = trimmed.lastIndex(of: "/") {
      return String(trimmed[trimmed.index(after: slash)...])
    }
    return trimmed
  }
}
