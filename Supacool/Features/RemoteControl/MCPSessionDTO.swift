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

/// Acknowledgement for write tools. Writes are fire-and-observe: the action
/// is dispatched into the board's own flows, and the caller polls
/// list_sessions/read_session to see the effect.
nonisolated struct MCPActionReceipt: Codable, Equatable {
  let action: String
  let sessionID: String
  let note: String
}

nonisolated struct MCPSessionReading: Codable, Equatable {
  let session: MCPSessionSummary
  /// Terminal text for the requested scope; nil when the session has no
  /// live surface (detached / disconnected / not yet spawned).
  let screen: String?
  /// Present exactly when `screen` is nil — tells the remote agent why and
  /// what to do instead (usually: read the transcript).
  let screenUnavailableReason: String?
  /// Last N transcript entries, oldest first. Only present when the caller
  /// asked for a transcript tail.
  let transcript: [MCPTranscriptEntry]?
}

/// Flattened `TranscriptEntry` for remote consumption: a discriminant, a
/// timestamp, and up to two strings. Remote agents don't need the full
/// per-case payloads; they need "what happened, when, and what was said."
nonisolated struct MCPTranscriptEntry: Codable, Equatable {
  let kind: String
  let at: String
  let text: String?
  let detail: String?

  init(entry: TranscriptEntry) {
    self.at = entry.timestamp.formatted(.iso8601)
    switch entry {
    case .input(let text, _):
      self.kind = "input"
      self.text = Self.truncated(text)
      self.detail = nil
    case .outputTurn(_, let delta, _):
      self.kind = "output"
      self.text = Self.truncated(delta)
      self.detail = nil
    case .hookBusy(let active, _, let source, _, _):
      self.kind = "busy"
      self.text = active ? "agent started working" : "agent went idle"
      self.detail = source
    case .hookEvent(_, let event, let title, let body, _, _, _, _):
      self.kind = "hookEvent"
      self.text = Self.truncated([title, body].compactMap(\.self).joined(separator: ": "))
      self.detail = event
    case .awaitingInputChanged(let active, let source, _, _):
      self.kind = "awaitingInput"
      self.text = active ? "session started waiting for input" : "session stopped waiting for input"
      self.detail = source
    case .sessionLifecycle(let kind, let context, _):
      self.kind = "lifecycle"
      self.text = kind
      self.detail = context
    case .autoObserver(_, _, let layer, let decision, _, _):
      self.kind = "autoObserver"
      self.text = decision
      self.detail = layer
    case .backgroundInference(let purpose, _, _, _, let error, _, _):
      self.kind = "backgroundInference"
      self.text = purpose
      self.detail = error
    }
  }

  /// Individual entries are capped so one giant paste or agent turn can't
  /// blow up the whole response; the interesting part of a turn is its end.
  private static let maxEntryCharacters = 10_000

  private static func truncated(_ text: String) -> String {
    guard text.count > maxEntryCharacters else { return text }
    return "…[truncated]…" + text.suffix(maxEntryCharacters)
  }
}
