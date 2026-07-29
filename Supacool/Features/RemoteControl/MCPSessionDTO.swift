import Foundation

/// Wire shapes returned by the remote-control tools. Remote agents parse
/// these, so evolve them additively — never rename or repurpose a field.
nonisolated struct MCPSessionSummary: Codable, Equatable {
  let id: String
  let name: String
  let repositoryID: String
  let workspacePath: String
  /// Agent id (`claude`, `codex`, `pi`, or a user-defined slug); nil for a
  /// plain shell session.
  let agent: String?
  /// `BoardSessionStatus` raw value — exactly what the board card shows.
  let status: String
  let isPriority: Bool
  let parked: Bool
  let isRemote: Bool
  let remoteConnectionLost: Bool
  let createdAt: String
  let lastActivityAt: String

  init(session: AgentSession, status: BoardSessionStatus) {
    self.id = session.id.uuidString
    self.name = session.displayName
    self.repositoryID = session.repositoryID
    self.workspacePath = session.currentWorkspacePath
    self.agent = session.agent?.id
    self.status = status.rawValue
    self.isPriority = session.isPriority
    self.parked = session.parked
    self.isRemote = session.isRemote
    self.remoteConnectionLost = session.remoteConnectionLost
    self.createdAt = Self.timestamp(session.createdAt)
    self.lastActivityAt = Self.timestamp(session.lastActivityAt)
  }

  private static func timestamp(_ date: Date) -> String {
    date.formatted(.iso8601)
  }
}

nonisolated struct MCPSessionList: Codable, Equatable {
  let sessions: [MCPSessionSummary]
}
