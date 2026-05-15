import Foundation

/// What a terminal inside an `AgentSession` represents.
///
/// `.agent` — a tab running a coding-agent CLI (claude-code, codex, pi, …).
/// Each agent terminal carries its own resume id and busy/idle state.
///
/// `.shell` — a plain user-driven shell tab. Has no agent, no resume id,
/// and never contributes to the session's card status. Counts toward the
/// `+N sh` composition pill.
nonisolated enum SessionTerminalRole: String, Codable, Sendable {
  case agent
  case shell
}

/// One terminal inside an `AgentSession`'s composition.
///
/// A session is conceptually an ordered list of these. The first one
/// (canonically `session.primaryTerminal`) drives the board card's status
/// and is what the user sees when they tap the card. Additional terminals
/// (shells or even secondary agents) live behind a session-scoped tab strip.
///
/// `id` doubles as the Ghostty `TerminalTabID` for the tab that hosts this
/// terminal. For backward compatibility with single-terminal sessions
/// created before the composition feature, the primary terminal's `id` is
/// the same UUID as the session's `id`.
nonisolated struct SessionTerminal: Identifiable, Hashable, Codable, Sendable {
  let id: UUID
  var role: SessionTerminalRole

  /// The coding-agent CLI this terminal was spawned with. `nil` for a
  /// `.shell` terminal, and only meaningful when `role == .agent`.
  var agent: AgentType?

  /// What the user typed when this terminal was created. Empty for shell
  /// terminals (or holds an initial command if the shell was spawned with
  /// one piped in). Replayed on Rerun.
  var initialPrompt: String

  /// Agent-native session id captured from the hook payload — Claude
  /// Code's `session_id`, or the Codex equivalent. Absent until the first
  /// hook event arrives. Drives `claude --resume <id>` / `codex resume <id>`.
  var agentNativeSessionID: String?

  /// Optional tab-title override. `nil` falls back to a default derived
  /// from the agent type or initial prompt.
  var displayName: String?

  /// Working directory observed when the layout was last captured. Used to
  /// spawn the restored terminal in the right cwd on relaunch.
  var workingDirectoryHint: String?

  let createdAt: Date
  var lastActivityAt: Date

  /// The last busy state we observed for THIS terminal, persisted. Used
  /// on relaunch to distinguish "the agent was idle when the app died"
  /// (`.detached`) from "the agent was actively working" (`.interrupted`).
  var lastKnownBusy: Bool

  /// Becomes true when any agent hook event arrives for this terminal.
  /// Before this fires the CLI may still be booting; an idle terminal
  /// does not yet mean the agent is waiting on the user.
  var hasObservedInitialAgentEvent: Bool

  /// Becomes true the first time THIS terminal transitions busy → idle.
  /// Distinguishes "just spawned, first prompt running" from "agent
  /// finished, waiting on me".
  var hasCompletedAtLeastOnce: Bool

  /// Timestamp of the most recent busy-state flip on this terminal.
  /// Powers the brief grace window in the board classifier.
  var lastBusyTransitionAt: Date?

  init(
    id: UUID = UUID(),
    role: SessionTerminalRole,
    agent: AgentType? = nil,
    initialPrompt: String = "",
    agentNativeSessionID: String? = nil,
    displayName: String? = nil,
    workingDirectoryHint: String? = nil,
    createdAt: Date = Date(),
    lastActivityAt: Date = Date(),
    lastKnownBusy: Bool = false,
    hasObservedInitialAgentEvent: Bool = false,
    hasCompletedAtLeastOnce: Bool = false,
    lastBusyTransitionAt: Date? = nil
  ) {
    self.id = id
    self.role = role
    self.agent = agent
    self.initialPrompt = initialPrompt
    self.agentNativeSessionID = agentNativeSessionID
    self.displayName = displayName
    self.workingDirectoryHint = workingDirectoryHint
    self.createdAt = createdAt
    self.lastActivityAt = lastActivityAt
    self.lastKnownBusy = lastKnownBusy
    self.hasObservedInitialAgentEvent = hasObservedInitialAgentEvent
    self.hasCompletedAtLeastOnce = hasCompletedAtLeastOnce
    self.lastBusyTransitionAt = lastBusyTransitionAt
  }

  // Forward-compatible Codable — convention documented in
  // docs/agent-guides/persistence.md.
  enum CodingKeys: String, CodingKey {
    case id, role, agent, initialPrompt, agentNativeSessionID
    case displayName, workingDirectoryHint
    case createdAt, lastActivityAt
    case lastKnownBusy, hasObservedInitialAgentEvent, hasCompletedAtLeastOnce
    case lastBusyTransitionAt
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(UUID.self, forKey: .id)
    role = try c.decodeIfPresent(SessionTerminalRole.self, forKey: .role) ?? .shell
    agent = try c.decodeIfPresent(AgentType.self, forKey: .agent)
    initialPrompt = try c.decodeIfPresent(String.self, forKey: .initialPrompt) ?? ""
    agentNativeSessionID = try c.decodeIfPresent(String.self, forKey: .agentNativeSessionID)
    displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
    workingDirectoryHint = try c.decodeIfPresent(String.self, forKey: .workingDirectoryHint)
    createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    lastActivityAt = try c.decodeIfPresent(Date.self, forKey: .lastActivityAt) ?? Date()
    lastKnownBusy = try c.decodeIfPresent(Bool.self, forKey: .lastKnownBusy) ?? false
    hasObservedInitialAgentEvent =
      try c.decodeIfPresent(Bool.self, forKey: .hasObservedInitialAgentEvent) ?? false
    hasCompletedAtLeastOnce =
      try c.decodeIfPresent(Bool.self, forKey: .hasCompletedAtLeastOnce) ?? false
    lastBusyTransitionAt = try c.decodeIfPresent(Date.self, forKey: .lastBusyTransitionAt)
  }
}
