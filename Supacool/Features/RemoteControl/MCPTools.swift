import ComposableArchitecture
import Foundation
import MCP

/// Catalog and dispatch for the remote-control tools.
///
/// Handlers read the same sources the board UI reads — `@Shared(.agentSessions)`,
/// the terminal manager, board feature state — so what a remote agent sees is
/// exactly what the user would see on the Matrix Board.
@MainActor
struct MCPToolBox {
  let store: StoreOf<AppFeature>
  let terminalManager: WorktreeTerminalManager

  nonisolated static let listSessionsName = "list_sessions"
  nonisolated static let readSessionName = "read_session"

  nonisolated static let definitions: [Tool] = [
    Tool(
      name: listSessionsName,
      description: """
        List every agent session on the Supacool board with its live status \
        (the same classification the board cards show): inProgress, waitingOnMe, \
        awaitingInput, waitingForChecks (waiting on CI/review), detached, \
        interrupted, fresh, parked, or disconnected.
        """,
      inputSchema: .object([
        "type": "object",
        "properties": .object([:]),
      ])
    ),
    Tool(
      name: readSessionName,
      description: """
        Read a session's terminal contents and/or transcript tail. `scope` "screen" \
        returns the visible viewport, "scrollback" the full buffer. `transcript_tail` \
        returns the last N transcript entries (prompts, agent turns, lifecycle events).
        """,
      inputSchema: .object([
        "type": "object",
        "properties": .object([
          "session_id": .object([
            "type": "string",
            "description": "Session UUID from list_sessions",
          ]),
          "scope": .object([
            "type": "string",
            "enum": .array(["screen", "scrollback"]),
            "description": "How much terminal buffer to read (default: screen)",
          ]),
          "transcript_tail": .object([
            "type": "integer",
            "description": "Also return the last N transcript entries (default 0, max 200)",
          ]),
        ]),
        "required": .array(["session_id"]),
      ])
    ),
  ]

  func call(name: String, arguments: [String: Value]?) throws -> CallTool.Result {
    switch name {
    case Self.listSessionsName:
      return try listSessions()
    case Self.readSessionName:
      throw MCPError.internalError("read_session is not implemented yet")
    default:
      throw MCPError.methodNotFound("Unknown tool: \(name)")
    }
  }

  // MARK: - list_sessions

  private func listSessions() throws -> CallTool.Result {
    let state = store.state
    let classifier = BoardSessionClassifier(
      terminalManager: terminalManager,
      prReferenceSnapshots: state.board.prReferenceSnapshots,
      reinitializingSessionIDs: state.board.reinitializingSessionIDs,
      repositories: state.repositories.repositories,
      worktreeInfoByID: state.repositories.worktreeInfoByID
    )
    let payload = MCPSessionList(
      sessions: state.board.sessions.map { session in
        MCPSessionSummary(session: session, status: classifier.classify(session))
      }
    )
    return try Self.result(payload)
  }

  // MARK: - Result encoding

  /// Tool results carry the payload twice, per MCP convention: prettified
  /// JSON in `content` for consumption as text, and the same object as
  /// `structuredContent` for clients that read it directly.
  nonisolated static func result<Payload: Codable>(_ payload: Payload) throws -> CallTool.Result {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let json = String(bytes: try encoder.encode(payload), encoding: .utf8) else {
      throw MCPError.internalError("payload is not valid UTF-8")
    }
    return try CallTool.Result(
      content: [.text(text: json, annotations: nil, _meta: nil)],
      structuredContent: payload
    )
  }
}
