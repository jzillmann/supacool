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

  private func makeToolBox(
    readScreenContents: ((Worktree.ID, TerminalTabID) -> String?)? = nil,
    sendCommand: ((TerminalClient.Command) -> Void)? = nil,
    dispatchBoardAction: ((BoardFeature.Action) -> Void)? = nil
  ) -> MCPToolBox {
    let store = Store(initialState: AppFeature.State()) {
      EmptyReducer<AppFeature.State, AppFeature.Action>()
    }
    return MCPToolBox(
      store: store,
      terminalManager: WorktreeTerminalManager(
        runtime: GhosttyRuntime(),
        readScreenContents: readScreenContents
      ),
      sendCommand: sendCommand,
      dispatchBoardAction: dispatchBoardAction
    )
  }

  private func allowWrites(_ allowed: Bool = true) {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.remoteControlServerAllowsWrites = allowed }
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

  // MARK: - read_session

  private func decodeSessionReading(_ result: CallTool.Result) throws -> MCPSessionReading {
    guard case .text(let json, _, _) = result.content.first else {
      throw MCPError.internalError("expected text content")
    }
    return try JSONDecoder().decode(MCPSessionReading.self, from: Data(json.utf8))
  }

  @Test(.dependencies) func readSessionReturnsScreenContents() throws {
    @Shared(.agentSessions) var sessions
    let session = Self.sampleSession(name: "Live")
    $sessions.withLock { $0 = [session] }

    let toolBox = makeToolBox(readScreenContents: { _, _ in "❯ claude is asking a question" })
    let result = try toolBox.call(
      name: MCPToolBox.readSessionName,
      arguments: ["session_id": .string(session.id.uuidString)]
    )
    let reading = try decodeSessionReading(result)
    #expect(reading.screen == "❯ claude is asking a question")
    #expect(reading.screenUnavailableReason == nil)
    #expect(reading.transcript == nil)
    #expect(reading.session.id == session.id.uuidString)
  }

  @Test(.dependencies) func readSessionDegradesWhenNoSurfaceExists() throws {
    @Shared(.agentSessions) var sessions
    let session = Self.sampleSession(name: "Gone")
    $sessions.withLock { $0 = [session] }

    let result = try makeToolBox().call(
      name: MCPToolBox.readSessionName,
      arguments: ["session_id": .string(session.id.uuidString)]
    )
    let reading = try decodeSessionReading(result)
    #expect(reading.screen == nil)
    let reason = try #require(reading.screenUnavailableReason)
    #expect(reason.contains("detached"))
    #expect(reason.contains("transcript_tail"))
  }

  @Test(.dependencies) func readSessionReturnsTranscriptTail() throws {
    @Shared(.agentSessions) var sessions
    let session = Self.sampleSession(name: "History")
    $sessions.withLock { $0 = [session] }

    let url = try #require(TranscriptReader.transcriptURL(rawTabID: session.id))
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let entries: [TranscriptEntry] = [
      .input(text: "please fix the tests", at: Date(timeIntervalSince1970: 1)),
      .outputTurn(fullText: "full", delta: "done, tests green", at: Date(timeIntervalSince1970: 2)),
      .sessionLifecycle(kind: "parked", context: nil, at: Date(timeIntervalSince1970: 3)),
    ]
    let lines = try entries.map { entry in
      try #require(String(bytes: try encoder.encode(entry), encoding: .utf8))
    }
    try Data(lines.joined(separator: "\n").utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let result = try makeToolBox().call(
      name: MCPToolBox.readSessionName,
      arguments: [
        "session_id": .string(session.id.uuidString),
        "transcript_tail": .int(2),
      ]
    )
    let reading = try decodeSessionReading(result)
    let transcript = try #require(reading.transcript)
    #expect(transcript.count == 2)
    #expect(transcript[0].kind == "output")
    #expect(transcript[0].text == "done, tests green")
    #expect(transcript[1].kind == "lifecycle")
    #expect(transcript[1].text == "parked")
  }

  // MARK: - Write gating

  @Test(.dependencies) func writeToolsHiddenAndRefusedWhenToggleOff() throws {
    @Shared(.agentSessions) var sessions
    let session = Self.sampleSession(name: "Gated")
    $sessions.withLock { $0 = [session] }
    allowWrites(false)

    let toolBox = makeToolBox(readScreenContents: { _, _ in "❯" })
    #expect(toolBox.availableTools().map(\.name) == ["list_sessions", "read_session"])
    #expect(throws: MCPError.self) {
      try toolBox.call(
        name: MCPToolBox.sendInputName,
        arguments: ["session_id": .string(session.id.uuidString), "text": .string("hi")]
      )
    }
  }

  @Test(.dependencies) func writeToolsListedWhenToggleOn() throws {
    allowWrites()
    let names = makeToolBox().availableTools().map(\.name)
    #expect(
      names == ["list_sessions", "read_session", "send_input", "resume_session", "rerun_session"]
    )
  }

  // MARK: - send_input

  @Test(.dependencies) func sendInputSubmitsPromptToLiveSession() throws {
    @Shared(.agentSessions) var sessions
    let session = Self.sampleSession(name: "Live")
    $sessions.withLock { $0 = [session] }
    allowWrites()

    var recorded: [TerminalClient.Command] = []
    let toolBox = makeToolBox(
      readScreenContents: { _, _ in "❯ which migration strategy?" },
      sendCommand: { recorded.append($0) }
    )
    let result = try toolBox.call(
      name: MCPToolBox.sendInputName,
      arguments: ["session_id": .string(session.id.uuidString), "text": .string("use option B")]
    )
    let tabID = TerminalTabID(rawValue: session.id)
    #expect(
      recorded == [.sendPrompt(worktreeID: session.worktreeID, tabID: tabID, text: "use option B")]
    )
    #expect(result.structuredContent != nil)
  }

  @Test(.dependencies) func sendInputWithoutSubmitTypesRawText() throws {
    @Shared(.agentSessions) var sessions
    let session = Self.sampleSession(name: "Raw")
    $sessions.withLock { $0 = [session] }
    allowWrites()

    var recorded: [TerminalClient.Command] = []
    let toolBox = makeToolBox(
      readScreenContents: { _, _ in "continue? [y/n]" },
      sendCommand: { recorded.append($0) }
    )
    _ = try toolBox.call(
      name: MCPToolBox.sendInputName,
      arguments: [
        "session_id": .string(session.id.uuidString),
        "text": .string("y"),
        "submit": .bool(false),
      ]
    )
    let tabID = TerminalTabID(rawValue: session.id)
    #expect(recorded == [.sendText(worktreeID: session.worktreeID, tabID: tabID, text: "y")])
  }

  @Test(.dependencies) func sendInputRefusedWithoutLiveSurface() throws {
    @Shared(.agentSessions) var sessions
    let session = Self.sampleSession(name: "Dead")
    $sessions.withLock { $0 = [session] }
    allowWrites()

    #expect(throws: MCPError.self) {
      try makeToolBox().call(
        name: MCPToolBox.sendInputName,
        arguments: ["session_id": .string(session.id.uuidString), "text": .string("hello")]
      )
    }
  }

  @Test(.dependencies) func sendInputRefusedWhileBusyUnlessForced() throws {
    @Shared(.agentSessions) var sessions
    var session = Self.sampleSession(name: "Busy")
    session.terminals[0].lastKnownBusy = true
    $sessions.withLock { [session] in $0 = [session] }
    allowWrites()

    var recorded: [TerminalClient.Command] = []
    let toolBox = makeToolBox(
      readScreenContents: { _, _ in "⏺ working…" },
      sendCommand: { recorded.append($0) }
    )
    #expect(throws: MCPError.self) {
      try toolBox.call(
        name: MCPToolBox.sendInputName,
        arguments: ["session_id": .string(session.id.uuidString), "text": .string("stop")]
      )
    }
    #expect(recorded.isEmpty)

    _ = try toolBox.call(
      name: MCPToolBox.sendInputName,
      arguments: [
        "session_id": .string(session.id.uuidString),
        "text": .string("stop"),
        "force": .bool(true),
      ]
    )
    #expect(recorded.count == 1)
  }

  // MARK: - resume_session / rerun_session

  @Test(.dependencies) func resumeRoutesDirectWhenNativeSessionIDCaptured() throws {
    @Shared(.agentSessions) var sessions
    var session = Self.sampleSession(name: "Captured")
    session.terminals[0].agentNativeSessionID = "abc-123"
    $sessions.withLock { [session] in $0 = [session] }
    allowWrites()

    var actions: [BoardFeature.Action] = []
    let toolBox = makeToolBox(dispatchBoardAction: { actions.append($0) })
    _ = try toolBox.call(
      name: MCPToolBox.resumeSessionName,
      arguments: ["session_id": .string(session.id.uuidString)]
    )
    #expect(
      actions == [
        .resumeDetachedSession(id: session.id, repositories: [], focusOnComplete: false)
      ]
    )
  }

  @Test(.dependencies) func resumeRoutesToPickerWithoutNativeSessionID() throws {
    @Shared(.agentSessions) var sessions
    let session = Self.sampleSession(name: "Uncaptured")
    $sessions.withLock { $0 = [session] }
    allowWrites()

    var actions: [BoardFeature.Action] = []
    let toolBox = makeToolBox(dispatchBoardAction: { actions.append($0) })
    _ = try toolBox.call(
      name: MCPToolBox.resumeSessionName,
      arguments: ["session_id": .string(session.id.uuidString)]
    )
    #expect(actions == [.resumeDetachedSessionWithPicker(id: session.id, repositories: [])])
  }

  @Test(.dependencies) func rerunDispatchesForDetachedAgentSession() throws {
    @Shared(.agentSessions) var sessions
    let session = Self.sampleSession(name: "Rerun")
    $sessions.withLock { $0 = [session] }
    allowWrites()

    var actions: [BoardFeature.Action] = []
    let toolBox = makeToolBox(dispatchBoardAction: { actions.append($0) })
    _ = try toolBox.call(
      name: MCPToolBox.rerunSessionName,
      arguments: ["session_id": .string(session.id.uuidString)]
    )
    #expect(actions == [.rerunDetachedSession(id: session.id, repositories: [])])
  }

  @Test(.dependencies) func readSessionRejectsBadArguments() throws {
    @Shared(.agentSessions) var sessions
    let session = Self.sampleSession(name: "Args")
    $sessions.withLock { $0 = [session] }
    let toolBox = makeToolBox()

    #expect(throws: MCPError.self) {
      try toolBox.call(name: MCPToolBox.readSessionName, arguments: nil)
    }
    #expect(throws: MCPError.self) {
      try toolBox.call(
        name: MCPToolBox.readSessionName,
        arguments: ["session_id": .string(UUID().uuidString)]
      )
    }
    #expect(throws: MCPError.self) {
      try toolBox.call(
        name: MCPToolBox.readSessionName,
        arguments: [
          "session_id": .string(session.id.uuidString),
          "scope": .string("everything"),
        ]
      )
    }
    #expect(throws: MCPError.self) {
      try toolBox.call(
        name: MCPToolBox.readSessionName,
        arguments: [
          "session_id": .string(session.id.uuidString),
          "transcript_tail": .int(-1),
        ]
      )
    }
  }
}
