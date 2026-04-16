import Foundation

/// A persistent agent-driven terminal session: one PTY inside a tab, running
/// claude-code or codex in interactive mode with an initial prompt.
///
/// Each session shows up as a card on the board. Status (in-progress / waiting
/// on me) is DERIVED at render time from the underlying terminal's agent-busy
/// signal — not stored here. What IS stored is the identity of the session,
/// its backing directory, and a lightweight flag that records whether it's
/// ever gone busy-then-idle (so we can tell "just created" apart from
/// "finished and waiting").
nonisolated struct AgentSession: Identifiable, Hashable, Codable, Sendable {
  /// Stable session identity. Also used as the Ghostty tab ID so the
  /// underlying `WorktreeTerminalState` tab is addressable by session ID.
  let id: UUID

  /// The registered repo this session belongs to (its `Repository.ID`,
  /// which is the repo root path).
  let repositoryID: String

  /// The workspace backing this session — either the repo root (directory
  /// mode) or a git worktree path. Matches `Worktree.ID` in the existing
  /// `WorktreeTerminalManager` states dictionary.
  let worktreeID: String

  /// The coding-agent CLI this session was spawned with. `nil` means a raw
   /// shell session — no agent CLI was invoked, just a terminal tab (with an
   /// optional initial command piped in).
   let agent: AgentType?

  /// What the user typed when creating the session. We keep this verbatim
  /// so "rerun" can replay it after a relaunch.
  let initialPrompt: String

  /// Human-readable card title. Defaults to a derivation of `initialPrompt`;
  /// user can rename.
  var displayName: String

  let createdAt: Date
  var lastActivityAt: Date

  /// Becomes true the first time the session transitions busy → idle. Used
  /// to distinguish "just spawned, first prompt still running" (stays in
  /// In Progress) from "agent finished, waiting on me" (moves to Waiting on Me).
  var hasCompletedAtLeastOnce: Bool

  /// The last busy state we observed for this session, persisted. Used on
  /// relaunch to distinguish "the session was idle when the app went away"
  /// (`.detached` — safe) from "the agent was actively working when the
  /// app died" (`.interrupted` — its turn was lost).
  var lastKnownBusy: Bool

  /// Timestamp of the most recent busy-state flip. Used by the board
  /// classifier to keep cards in the working bucket for a brief moment
  /// after a busy → idle transition so transient hook gaps don't cause
  /// visible flicker.
  var lastBusyTransitionAt: Date?

  /// Whether this session owns a dedicated backing worktree that Supacool
  /// created for it and should delete when the session itself is removed.
  /// False for repo-root sessions and sessions attached to a pre-existing
  /// worktree.
  var removeBackingWorktreeOnDelete: Bool

  /// Agent-native session identifier captured from the hook payload:
  /// Claude Code's `session_id`, or the Codex equivalent. Absent until the
  /// first hook event arrives. Used to auto-resume (`claude --resume <id>` /
  /// `codex resume <id>`) across app relaunches.
  var agentNativeSessionID: String?

  /// User explicitly parked this session: its PTY was destroyed to free
  /// resources, but the metadata (prompt, captured resume id) is
  /// preserved so the user can resume later. Differs from `.detached`
  /// only in *intent* — parked sessions live in their own bottom bucket
  /// and stay out of keyboard-nav cycling until resumed.
  var parked: Bool

  /// When true, the Auto-Observer monitors this session: on each idle
  /// transition it reads the terminal screen, decides if there's an
  /// obvious response, and types it automatically.
  var autoObserver: Bool

  /// Free-form instructions for the Auto-Observer: acceptance criteria,
  /// things to allow or deny, conditions to stop on, etc. Empty string
  /// means "use default heuristics only."
  var autoObserverPrompt: String

  /// External work-item references parsed from the session's conversation
  /// (Linear tickets, GitHub PRs). Populated lazily by the scanner on
  /// card appearance and refreshed on hook activity.
  var references: [SessionReference]

  /// When the references list was last computed. Used to decide whether
  /// a re-scan is needed: if `lastActivityAt > referencesScannedAt` the
  /// next card-appearance triggers a refresh.
  var referencesScannedAt: Date?

  init(
    id: UUID = UUID(),
    repositoryID: String,
    worktreeID: String,
    agent: AgentType?,
    initialPrompt: String,
    displayName: String? = nil,
    createdAt: Date = Date(),
    lastActivityAt: Date = Date(),
    hasCompletedAtLeastOnce: Bool = false,
    lastKnownBusy: Bool = false,
    lastBusyTransitionAt: Date? = nil,
    removeBackingWorktreeOnDelete: Bool = false,
    agentNativeSessionID: String? = nil,
    parked: Bool = false,
    autoObserver: Bool = false,
    autoObserverPrompt: String = "",
    references: [SessionReference] = [],
    referencesScannedAt: Date? = nil
  ) {
    self.id = id
    self.repositoryID = repositoryID
    self.worktreeID = worktreeID
    self.agent = agent
    self.initialPrompt = initialPrompt
    self.displayName = displayName ?? Self.deriveDisplayName(from: initialPrompt, fallbackID: id)
    self.createdAt = createdAt
    self.lastActivityAt = lastActivityAt
    self.hasCompletedAtLeastOnce = hasCompletedAtLeastOnce
    self.lastKnownBusy = lastKnownBusy
    self.lastBusyTransitionAt = lastBusyTransitionAt
    self.removeBackingWorktreeOnDelete = removeBackingWorktreeOnDelete
    self.agentNativeSessionID = agentNativeSessionID
    self.parked = parked
    self.autoObserver = autoObserver
    self.autoObserverPrompt = autoObserverPrompt
    self.references = references
    self.referencesScannedAt = referencesScannedAt
  }

  // Forward-compatible Codable — convention documented in
  // docs/agent-guides/persistence.md.
  //
  // Missing fields decode to their struct default rather than failing the
  // whole file. Prevents "all sessions disappeared" regressions any time
  // we add a new field to AgentSession and relaunch against a previously-
  // written sessions file.
  //
  // When adding a new field: bump CodingKeys, add one
  // `decodeIfPresent ?? default` line below. Do NOT fall back to the
  // synthesized init — it will break backward compat silently.
  enum CodingKeys: String, CodingKey {
    case id, repositoryID, worktreeID, agent, initialPrompt, displayName
    case createdAt, lastActivityAt, hasCompletedAtLeastOnce, lastKnownBusy, lastBusyTransitionAt
    case removeBackingWorktreeOnDelete
    case agentNativeSessionID, parked
    case autoObserver, autoObserverPrompt
    case references, referencesScannedAt
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(UUID.self, forKey: .id)
    repositoryID = try c.decode(String.self, forKey: .repositoryID)
    worktreeID = try c.decode(String.self, forKey: .worktreeID)
    agent = try c.decodeIfPresent(AgentType.self, forKey: .agent)
    initialPrompt = try c.decode(String.self, forKey: .initialPrompt)
    displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
      ?? Self.deriveDisplayName(from: initialPrompt, fallbackID: id)
    createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    lastActivityAt = try c.decodeIfPresent(Date.self, forKey: .lastActivityAt) ?? Date()
    hasCompletedAtLeastOnce =
      try c.decodeIfPresent(Bool.self, forKey: .hasCompletedAtLeastOnce) ?? false
    lastKnownBusy = try c.decodeIfPresent(Bool.self, forKey: .lastKnownBusy) ?? false
    lastBusyTransitionAt = try c.decodeIfPresent(Date.self, forKey: .lastBusyTransitionAt)
    removeBackingWorktreeOnDelete =
      try c.decodeIfPresent(Bool.self, forKey: .removeBackingWorktreeOnDelete) ?? false
    agentNativeSessionID = try c.decodeIfPresent(String.self, forKey: .agentNativeSessionID)
    parked = try c.decodeIfPresent(Bool.self, forKey: .parked) ?? false
    autoObserver = try c.decodeIfPresent(Bool.self, forKey: .autoObserver) ?? false
    autoObserverPrompt = try c.decodeIfPresent(String.self, forKey: .autoObserverPrompt) ?? ""
    references = try c.decodeIfPresent([SessionReference].self, forKey: .references) ?? []
    referencesScannedAt = try c.decodeIfPresent(Date.self, forKey: .referencesScannedAt)
  }

  /// Pulls the first ~5 meaningful words from the prompt, title-cases them,
  /// and truncates to a short label. Falls back to "Session <short-id>".
  nonisolated static func deriveDisplayName(from prompt: String, fallbackID: UUID) -> String {
    let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return "Session " + String(fallbackID.uuidString.prefix(8))
    }
    // Split on whitespace + punctuation, drop empties, take the first 5.
    let words = trimmed
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "_" })
      .prefix(5)
      .map(String.init)
    guard !words.isEmpty else {
      return "Session " + String(fallbackID.uuidString.prefix(8))
    }
    let candidate = words.joined(separator: " ")
    // Cap overall length so narrow cards don't explode.
    return String(candidate.prefix(60))
  }
}
