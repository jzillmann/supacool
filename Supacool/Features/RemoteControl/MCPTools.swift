import ComposableArchitecture
import Foundation
import MCP

/// Catalog and dispatch for the remote-control tools.
///
/// Read handlers consume the same sources the board UI reads — `@Shared`
/// sessions, the terminal manager, board feature state — so what a remote
/// agent sees is exactly what the user would see on the Matrix Board. Write
/// handlers reuse the board's own proven paths: `sendPrompt` (PR Pulse
/// auto-resume's synthesized-Enter submission) and the card buttons' resume
/// routing (`BoardResumeEligibility`).
///
/// Write tools are gated by `remoteControlServerAllowsWrites` — hidden from
/// `tools/list` AND refused at call time, checked per request.
@MainActor
struct MCPToolBox {
  let store: StoreOf<AppFeature>
  let terminalManager: WorktreeTerminalManager
  /// Injectable seams so tests can record dispatches instead of driving a
  /// real ghostty tab / live reducer. Production defaults are the real paths.
  let sendCommand: (TerminalClient.Command) -> Void
  let dispatchBoardAction: (BoardFeature.Action) -> Void

  init(
    store: StoreOf<AppFeature>,
    terminalManager: WorktreeTerminalManager,
    sendCommand: ((TerminalClient.Command) -> Void)? = nil,
    dispatchBoardAction: ((BoardFeature.Action) -> Void)? = nil
  ) {
    self.store = store
    self.terminalManager = terminalManager
    self.sendCommand = sendCommand ?? { terminalManager.handleCommand($0) }
    self.dispatchBoardAction = dispatchBoardAction ?? { store.send(.board($0)) }
  }

  nonisolated static let listSessionsName = "list_sessions"
  nonisolated static let readSessionName = "read_session"
  nonisolated static let sendInputName = "send_input"
  nonisolated static let resumeSessionName = "resume_session"
  nonisolated static let rerunSessionName = "rerun_session"
  nonisolated static let startSessionName = "start_session"

  nonisolated static let readDefinitions: [Tool] = [
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

  nonisolated static let writeDefinitions: [Tool] = [
    Tool(
      name: sendInputName,
      description: """
        Type into a session's terminal (its primary surface). With submit=true \
        (default) the text is sent as a prompt and submitted with a synthesized \
        Enter — use this to answer a waiting agent. submit=false types raw \
        keystrokes without submitting (e.g. a single "y", or arrow-key-free \
        menu answers). Refused while the agent is mid-turn unless force=true, \
        and refused when the session has no live terminal (resume_session first).
        """,
      inputSchema: .object([
        "type": "object",
        "properties": .object([
          "session_id": .object([
            "type": "string",
            "description": "Session UUID from list_sessions",
          ]),
          "text": .object([
            "type": "string",
            "description": "The text to type",
          ]),
          "submit": .object([
            "type": "boolean",
            "description": "Submit with a synthesized Enter keypress (default true)",
          ]),
          "force": .object([
            "type": "boolean",
            "description": "Send even while the agent is working (default false)",
          ]),
        ]),
        "required": .array(["session_id", "text"]),
      ])
    ),
    Tool(
      name: resumeSessionName,
      description: """
        Bring a detached/interrupted/parked session back to life, exactly like \
        the board's Resume button: continues the captured agent conversation \
        when one exists, falls back to the agent's own resume picker, or \
        restores the terminal layout for plain shell sessions. The revived \
        session appears with a live terminal shortly — poll list_sessions.
        """,
      inputSchema: .object([
        "type": "object",
        "properties": .object([
          "session_id": .object([
            "type": "string",
            "description": "Session UUID from list_sessions",
          ]),
        ]),
        "required": .array(["session_id"]),
      ])
    ),
    Tool(
      name: rerunSessionName,
      description: """
        Re-launch a detached agent session FRESH (its original prompt, a new \
        conversation) — the board's Rerun button. Use resume_session instead \
        when the existing conversation should continue.
        """,
      inputSchema: .object([
        "type": "object",
        "properties": .object([
          "session_id": .object([
            "type": "string",
            "description": "Session UUID from list_sessions",
          ]),
        ]),
        "required": .array(["session_id"]),
      ])
    ),
    Tool(
      name: startSessionName,
      description: """
        Start a brand-new agent session on the board — the remote New Terminal. \
        With `branch` set, a fresh worktree is created on that new branch \
        (pick a descriptive kebab-case name); without it the session runs at \
        the repo root. The session spawns asynchronously: poll list_sessions \
        for a new entry (a failed spawn surfaces as a draft pill on the board \
        instead). Do NOT retry on timeout — you may spawn a duplicate.
        """,
      inputSchema: .object([
        "type": "object",
        "properties": .object([
          "repository": .object([
            "type": "string",
            "description": "Repository — the repositoryID path from list_sessions, or the repo folder name",
          ]),
          "prompt": .object([
            "type": "string",
            "description": "The initial prompt for the agent",
          ]),
          "agent": .object([
            "type": "string",
            "description": "Agent id: claude (default), codex, pi, or a configured custom agent",
          ]),
          "branch": .object([
            "type": "string",
            "description": "Create a new worktree on this new branch; omit to run at the repo root",
          ]),
          "name": .object([
            "type": "string",
            "description": "Card title on the board (defaults to a prompt-derived name)",
          ]),
          "model": .object([
            "type": "string",
            "description": "Model passed to the agent's model flag (omit for the agent default)",
          ]),
        ]),
        "required": .array(["repository", "prompt"]),
      ])
    ),
  ]

  /// What `tools/list` advertises right now — write tools only when the
  /// separate writes toggle is on.
  func availableTools() -> [Tool] {
    writesAllowed
      ? Self.readDefinitions + Self.writeDefinitions
      : Self.readDefinitions
  }

  private var writesAllowed: Bool {
    @Shared(.settingsFile) var settingsFile
    return settingsFile.global.remoteControlServerAllowsWrites
  }

  func call(name: String, arguments: [String: Value]?) throws -> CallTool.Result {
    switch name {
    case Self.listSessionsName:
      return try listSessions()
    case Self.readSessionName:
      return try readSession(arguments: arguments)
    case Self.sendInputName, Self.resumeSessionName, Self.rerunSessionName,
      Self.startSessionName:
      guard writesAllowed else {
        throw MCPError.invalidRequest(
          "Write tools are disabled — enable \"Allow write access\" in "
            + "Settings → Remote Control on the Mac."
        )
      }
      switch name {
      case Self.sendInputName: return try sendInput(arguments: arguments)
      case Self.resumeSessionName: return try resumeSession(arguments: arguments)
      case Self.startSessionName: return try startSession(arguments: arguments)
      default: return try rerunSession(arguments: arguments)
      }
    default:
      throw MCPError.methodNotFound("Unknown tool: \(name)")
    }
  }

  // MARK: - list_sessions

  private func listSessions() throws -> CallTool.Result {
    let state = store.state
    let classifier = makeClassifier(state: state)
    let payload = MCPSessionList(
      sessions: state.board.sessions.map { session in
        MCPSessionSummary(session: session, status: classifier.classify(session))
      }
    )
    return try Self.result(payload)
  }

  // MARK: - read_session

  /// A full-scrollback read is capped at this many characters (tail kept —
  /// the most recent output is what a remote agent needs).
  nonisolated static let maxScreenCharacters = 200_000
  nonisolated static let maxTranscriptTail = 200

  private func readSession(arguments: [String: Value]?) throws -> CallTool.Result {
    let session = try session(from: arguments)

    let scope: GhosttySurfaceBridge.ScreenReadScope
    switch arguments?["scope"] {
    case nil, .string("screen"):
      scope = .screen
    case .string("scrollback"):
      scope = .surface
    default:
      throw MCPError.invalidParams(#"scope must be "screen" or "scrollback""#)
    }

    var transcriptTail = 0
    if let tailArgument = arguments?["transcript_tail"] {
      guard case .int(let requested) = tailArgument, requested >= 0 else {
        throw MCPError.invalidParams("transcript_tail must be a non-negative integer")
      }
      transcriptTail = min(requested, Self.maxTranscriptTail)
    }

    let status = makeClassifier(state: store.state).classify(session)
    let tabID = TerminalTabID(rawValue: session.id)
    let rawScreen = terminalManager.readScreenContents(
      worktreeID: session.worktreeID,
      tabID: tabID,
      scope: scope
    )
    let screen = rawScreen.map { text in
      text.count > Self.maxScreenCharacters
        ? "…[truncated]…" + text.suffix(Self.maxScreenCharacters)
        : text
    }

    let transcript: [MCPTranscriptEntry]? =
      transcriptTail > 0
      ? TranscriptReader.loadEntries(rawTabID: session.id)
        .suffix(transcriptTail)
        .map(MCPTranscriptEntry.init(entry:))
      : nil

    let payload = MCPSessionReading(
      session: MCPSessionSummary(session: session, status: status),
      screen: screen,
      screenUnavailableReason: screen == nil
        ? "session has no live terminal surface (status: \(status.rawValue)) — "
          + "use transcript_tail to read its history"
        : nil,
      transcript: transcript
    )
    return try Self.result(payload)
  }

  // MARK: - send_input

  private func sendInput(arguments: [String: Value]?) throws -> CallTool.Result {
    let session = try session(from: arguments)
    guard case .string(let text)? = arguments?["text"], !text.isEmpty else {
      throw MCPError.invalidParams("text must be a non-empty string")
    }
    let submit = try Self.boolArgument(arguments, "submit", default: true)
    let force = try Self.boolArgument(arguments, "force", default: false)

    let tabID = TerminalTabID(rawValue: session.id)
    // Same liveness probe PR Pulse auto-resume uses: a nil/blank primary
    // surface means there is nothing to type into.
    let screen = terminalManager.readPrimarySurfaceContents(
      worktreeID: session.worktreeID,
      tabID: tabID
    )
    guard let screen, !screen.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw MCPError.invalidRequest(
        "session has no live terminal surface — call resume_session first"
      )
    }

    let activity = terminalManager.agentActivity(worktreeID: session.worktreeID, tabID: tabID)
    let busy = activity == .working || activity == .deferredWork || session.lastKnownBusy
    if busy, !force {
      throw MCPError.invalidRequest(
        "agent is mid-turn — read_session to see what it's doing, or pass force: true to interrupt"
      )
    }

    if submit {
      sendCommand(.sendPrompt(worktreeID: session.worktreeID, tabID: tabID, text: text))
    } else {
      sendCommand(.sendText(worktreeID: session.worktreeID, tabID: tabID, text: text))
    }
    return try Self.result(
      MCPActionReceipt(
        action: submit ? "submitted" : "typed",
        sessionID: session.id.uuidString,
        note: submit
          ? "prompt submitted to the session's primary terminal — poll read_session to watch the agent pick it up"
          : "raw text typed without submitting"
      )
    )
  }

  // MARK: - resume_session / rerun_session

  private func resumeSession(arguments: [String: Value]?) throws -> CallTool.Result {
    let session = try session(from: arguments)
    let repositories = Array(store.state.repositories.repositories)
    let tabID = TerminalTabID(rawValue: session.id)
    let tabExists = terminalManager.sessionTabExists(
      worktreeID: session.worktreeID, tabID: tabID
    )
    guard !tabExists else {
      throw MCPError.invalidRequest("session already has a live terminal — use send_input")
    }
    let status = makeClassifier(state: store.state).classify(session)

    let route: String
    if session.agent == nil {
      dispatchBoardAction(.restoreShellSessionLayout(id: session.id, repositories: repositories))
      route = "shellRestore"
    } else if BoardResumeEligibility.canDirectResume(
      session, status: status, tabExists: tabExists, includingParked: true
    ) {
      // focusOnComplete false: a remote resume must not yank the local UI
      // into the full-screen terminal under the user's cursor.
      dispatchBoardAction(
        .resumeDetachedSession(id: session.id, repositories: repositories, focusOnComplete: false)
      )
      route = "resume"
    } else if BoardResumeEligibility.canResumeWithPicker(
      session, status: status, tabExists: tabExists, includingParked: true
    ) {
      dispatchBoardAction(
        .resumeDetachedSessionWithPicker(id: session.id, repositories: repositories)
      )
      route = "resumePicker"
    } else {
      throw MCPError.invalidRequest("session is not resumable (status: \(status.rawValue))")
    }
    return try Self.result(
      MCPActionReceipt(
        action: route,
        sessionID: session.id.uuidString,
        note: route == "resumePicker"
          ? "no captured conversation id — the agent's own resume picker was opened; "
            + "read_session to see it and send_input to drive it"
          : "resume dispatched — poll list_sessions until the status leaves detached/interrupted"
      )
    )
  }

  private func rerunSession(arguments: [String: Value]?) throws -> CallTool.Result {
    let session = try session(from: arguments)
    guard session.agent != nil else {
      throw MCPError.invalidRequest("shell sessions have nothing to rerun — use resume_session")
    }
    let tabID = TerminalTabID(rawValue: session.id)
    guard !terminalManager.sessionTabExists(worktreeID: session.worktreeID, tabID: tabID) else {
      throw MCPError.invalidRequest("session already has a live terminal — use send_input")
    }
    dispatchBoardAction(
      .rerunDetachedSession(
        id: session.id,
        repositories: Array(store.state.repositories.repositories)
      )
    )
    return try Self.result(
      MCPActionReceipt(
        action: "rerun",
        sessionID: session.id.uuidString,
        note: "fresh run dispatched with the session's original prompt — "
          + "poll list_sessions until it turns inProgress"
      )
    )
  }

  // MARK: - start_session

  private struct StartSessionArguments {
    let repository: Repository
    let prompt: String
    let agent: AgentType?
    let selection: WorkspaceSelection
    let branchNote: String
    let model: String?
    let explicitName: String?
  }

  private func parseStartSessionArguments(
    _ arguments: [String: Value]?
  ) throws -> StartSessionArguments {
    guard case .string(let repositoryQuery)? = arguments?["repository"], !repositoryQuery.isEmpty
    else {
      throw MCPError.invalidParams("repository is required — a repositoryID path or repo name")
    }
    guard case .string(let prompt)? = arguments?["prompt"],
      !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw MCPError.invalidParams("prompt must be a non-empty string")
    }

    let repositories = store.state.repositories.repositories
    guard let repository = Self.matchRepository(repositoryQuery, in: repositories) else {
      let known = repositories.map(\.name).joined(separator: ", ")
      throw MCPError.invalidParams(
        "no repository matches \"\(repositoryQuery)\" — known repositories: \(known)"
      )
    }

    let agent: AgentType?
    switch arguments?["agent"] {
    case nil:
      agent = AgentRegistry.entry(forID: "claude")
    case .string(let agentID):
      guard let resolved = AgentRegistry.entry(forID: agentID) else {
        let known = AgentRegistry.allAgents.map(\.id).joined(separator: ", ")
        throw MCPError.invalidParams("unknown agent \"\(agentID)\" — available: \(known)")
      }
      agent = resolved
    default:
      throw MCPError.invalidParams("agent must be a string agent id")
    }

    let selection: WorkspaceSelection
    var branchNote = "at the repo root"
    switch arguments?["branch"] {
    case nil:
      selection = .repoRoot
    case .string(let branch) where !branch.trimmingCharacters(in: .whitespaces).isEmpty:
      // Best-effort collision pre-check so a remote spawn fails fast here
      // instead of queueing the interactive worktree-conflict alert on a
      // Mac nobody is sitting at. The spawn itself still guards the race.
      if let taken = repository.worktrees.first(where: { $0.name == branch }) {
        throw MCPError.invalidRequest(
          "branch \"\(branch)\" is already checked out at \(taken.id) — "
            + "pick another name, or find its session via list_sessions"
        )
      }
      selection = .newBranch(name: branch)
      branchNote = "in a new worktree on branch \(branch)"
    default:
      throw MCPError.invalidParams("branch must be a non-empty string")
    }

    var model: String?
    if case .string(let requestedModel)? = arguments?["model"] {
      model = requestedModel
    }
    var explicitName: String?
    if case .string(let requestedName)? = arguments?["name"],
      !requestedName.trimmingCharacters(in: .whitespaces).isEmpty
    {
      explicitName = requestedName
    }

    return StartSessionArguments(
      repository: repository,
      prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
      agent: agent,
      selection: selection,
      branchNote: branchNote,
      model: model,
      explicitName: explicitName
    )
  }

  private func startSession(arguments: [String: Value]?) throws -> CallTool.Result {
    let parsed = try parseStartSessionArguments(arguments)

    // Mirror the New Terminal sheet's submit defaults (NewTerminalFeature+
    // Create) so remote and local spawns behave identically.
    @Shared(.settingsFile) var settingsFile
    let sessionID = UUID()
    let request = SessionSpawner.LocalRequest(
      sessionID: sessionID,
      repository: parsed.repository,
      selection: parsed.selection,
      agent: parsed.agent,
      prompt: parsed.prompt,
      planMode: false,
      remoteControl: false,
      remoteControlName: nil,
      model: parsed.model,
      bypassPermissions: UserDefaults.standard.object(forKey: "supacool.bypassPermissions")
        as? Bool ?? true,
      fetchOriginBeforeCreation: settingsFile.global.fetchOriginBeforeWorktreeCreation,
      rerunOwnedWorktreeID: nil,
      pullRequestLookup: .idle,
      suggestedDisplayName: parsed.explicitName,
      removeBackingWorktreeOnDelete: NewTerminalFeature.shouldRemoveBackingWorktreeOnDelete(
        selection: parsed.selection
      )
    )
    let displayName =
      parsed.explicitName
      ?? AgentSession.deriveDisplayName(from: parsed.prompt, fallbackID: sessionID)
    let now = Date()
    let draftSnapshot = Draft(
      id: UUID(),
      repositoryID: parsed.repository.id,
      prompt: parsed.prompt,
      agent: parsed.agent,
      workspaceQuery: {
        if case .newBranch(let name) = parsed.selection { return name }
        return ""
      }(),
      planMode: false,
      remoteControl: false,
      model: parsed.model,
      createdAt: now,
      updatedAt: now
    )

    dispatchBoardAction(
      .remoteStartSessionRequested(
        request: request,
        displayName: displayName,
        draftSnapshot: draftSnapshot
      )
    )
    return try Self.result(
      MCPActionReceipt(
        action: "startSession",
        sessionID: sessionID.uuidString,
        note: "spawn dispatched \(parsed.branchNote) of \(parsed.repository.name) — poll "
          + "list_sessions for this session id; if it never appears, the spawn failed and "
          + "left a draft pill on the board. Do not retry blindly."
      )
    )
  }

  /// Matches by exact repositoryID (root path, tolerating a trailing slash)
  /// or by repo folder name (unique match required).
  static func matchRepository(
    _ query: String,
    in repositories: IdentifiedArrayOf<Repository>
  ) -> Repository? {
    let normalizedQuery = query.hasSuffix("/") ? String(query.dropLast()) : query
    if let byID = repositories.first(where: { repository in
      let id = repository.id.hasSuffix("/") ? String(repository.id.dropLast()) : repository.id
      return id == normalizedQuery
    }) {
      return byID
    }
    let byName = repositories.filter { $0.name == normalizedQuery }
    return byName.count == 1 ? byName.first : nil
  }

  // MARK: - Shared helpers

  private func session(from arguments: [String: Value]?) throws -> AgentSession {
    guard case .string(let idString)? = arguments?["session_id"],
      let sessionID = UUID(uuidString: idString)
    else {
      throw MCPError.invalidParams("session_id must be a session UUID from list_sessions")
    }
    guard let session = store.state.board.sessions.first(where: { $0.id == sessionID }) else {
      throw MCPError.invalidParams("no session with id \(idString)")
    }
    return session
  }

  private func makeClassifier(state: AppFeature.State) -> BoardSessionClassifier {
    BoardSessionClassifier(
      terminalManager: terminalManager,
      prReferenceSnapshots: state.board.prReferenceSnapshots,
      reinitializingSessionIDs: state.board.reinitializingSessionIDs,
      repositories: state.repositories.repositories,
      worktreeInfoByID: state.repositories.worktreeInfoByID
    )
  }

  private nonisolated static func boolArgument(
    _ arguments: [String: Value]?,
    _ key: String,
    default defaultValue: Bool
  ) throws -> Bool {
    switch arguments?[key] {
    case nil:
      return defaultValue
    case .bool(let value):
      return value
    default:
      throw MCPError.invalidParams("\(key) must be a boolean")
    }
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
