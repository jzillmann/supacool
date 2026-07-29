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
        (the same classification the board cards show): in_progress, waiting_on_me, \
        awaiting_input, waiting_for_checks, detached, interrupted, fresh, parked, \
        or disconnected.
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
      throw MCPError.internalError("list_sessions is not implemented yet")
    case Self.readSessionName:
      throw MCPError.internalError("read_session is not implemented yet")
    default:
      throw MCPError.methodNotFound("Unknown tool: \(name)")
    }
  }
}
