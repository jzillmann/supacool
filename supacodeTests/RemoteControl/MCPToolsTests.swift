import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import MCP
import Testing

@testable import Supacool

/// list_sessions must mirror the board: same classifier, same inputs. These
/// fixtures cover the no-live-tab statuses (no ghostty surfaces exist in
/// tests, so every session's tab is gone — exactly the detached/interrupted/
/// disconnected/parked family).
@MainActor
// @Shared(.agentSessions) is process-global; serialize like BoardFeatureTests.
@Suite(.serialized)
struct MCPToolsTests {
  private static func sampleSession(name: String) -> AgentSession {
    AgentSession(
      id: UUID(),
      repositoryID: "/tmp/repo",
      worktreeID: "/tmp/repo",
      agent: .claude,
      initialPrompt: "Fix the failing tests",
      displayName: name
    )
  }

  private func makeToolBox() -> MCPToolBox {
    let store = Store(initialState: AppFeature.State()) {
      EmptyReducer<AppFeature.State, AppFeature.Action>()
    }
    return MCPToolBox(
      store: store,
      terminalManager: WorktreeTerminalManager(runtime: GhosttyRuntime())
    )
  }

  private func decodeSessionList(_ result: CallTool.Result) throws -> MCPSessionList {
    guard case .text(let json, _, _) = result.content.first else {
      throw MCPError.internalError("expected text content")
    }
    return try JSONDecoder().decode(MCPSessionList.self, from: Data(json.utf8))
  }

  @Test(.dependencies) func listSessionsClassifiesLikeTheBoard() throws {
    @Shared(.agentSessions) var sessions

    var parked = Self.sampleSession(name: "Parked")
    parked.parked = true

    var interrupted = Self.sampleSession(name: "Interrupted")
    interrupted.terminals[0].lastKnownBusy = true

    var disconnected = Self.sampleSession(name: "Remote")
    disconnected.remoteWorkspaceID = UUID()

    let detached = Self.sampleSession(name: "Detached")

    $sessions.withLock { $0 = [parked, interrupted, disconnected, detached] }

    let result = try makeToolBox().call(name: MCPToolBox.listSessionsName, arguments: nil)
    let list = try decodeSessionList(result)

    let statusByName = Dictionary(
      uniqueKeysWithValues: list.sessions.map { ($0.name, $0.status) }
    )
    #expect(statusByName["Parked"] == "parked")
    #expect(statusByName["Interrupted"] == "interrupted")
    #expect(statusByName["Remote"] == "disconnected")
    #expect(statusByName["Detached"] == "detached")
  }

  @Test(.dependencies) func listSessionsCarriesSessionMetadata() throws {
    @Shared(.agentSessions) var sessions
    let session = Self.sampleSession(name: "Metadata")
    $sessions.withLock { $0 = [session] }

    let result = try makeToolBox().call(name: MCPToolBox.listSessionsName, arguments: nil)
    let list = try decodeSessionList(result)

    let summary = try #require(list.sessions.first)
    #expect(summary.id == session.id.uuidString)
    #expect(summary.repositoryID == "/tmp/repo")
    #expect(summary.agent == "claude")
    #expect(summary.isRemote == false)
    #expect(summary.parked == false)
    // Structured content mirrors the text payload.
    #expect(result.structuredContent != nil)
  }

  @Test(.dependencies) func unknownToolThrowsMethodNotFound() throws {
    @Shared(.agentSessions) var sessions
    $sessions.withLock { $0 = [] }

    #expect(throws: MCPError.self) {
      try makeToolBox().call(name: "no_such_tool", arguments: nil)
    }
  }
}
