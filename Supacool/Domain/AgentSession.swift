import Foundation

/// A persistent agent-driven board session that owns one or more terminals.
///
/// A session shows up as a single card on the Matrix Board. Originally it
/// was a 1:1 wrapper around a single agent terminal — that role is now
/// played by `terminals[primaryTerminalID]`. The session itself holds the
/// shared identity (repository, worktree, displayName, priority, parked
/// flag, remote metadata, etc.) and an ordered list of terminals.
///
/// Status (in-progress / waiting on me) is DERIVED at render time from the
/// PRIMARY terminal's agent-busy signal — shells in the composition do not
/// promote status. See `BoardSessionStatus.classify`.
nonisolated struct AgentSession: Identifiable, Hashable, Codable, Sendable {
  /// Stable session identity. By convention also the `id` of the primary
  /// terminal (so the Ghostty tab for the canonical agent is addressable
  /// by `session.id`). Newly created sessions always satisfy
  /// `id == primaryTerminalID`, but the model no longer requires it so
  /// future flows can decouple them.
  let id: UUID

  /// The registered repo this session belongs to (its `Repository.ID`,
  /// which is the repo root path).
  let repositoryID: String

  /// The workspace backing this session — either the repo root (directory
  /// mode) or a git worktree path. Matches `Worktree.ID` in the existing
  /// `WorktreeTerminalManager` states dictionary.
  ///
  /// IMMUTABLE once the session is created. Used as the state-lookup key
  /// everywhere terminal state is accessed: `states[worktreeID]`, hook
  /// socket routing, `sessionTabExists`, `isAgentBusy`, etc.
  let worktreeID: String

  /// The worktree the user currently thinks of the session as running in.
  /// Mutable. Diverges from `worktreeID` after the "convert to worktree"
  /// popover.
  var currentWorkspacePath: String

  /// If non-nil, this session was created by tapping the matching bookmark
  /// pill.
  var sourceBookmarkID: Bookmark.ID?

  /// If non-nil, this session was spawned via "Debug session…" from the
  /// referenced source session id.
  var debugSourceSessionID: AgentSession.ID?

  /// Human-readable card title. Defaults to a derivation of the primary
  /// terminal's initial prompt; user can rename.
  var displayName: String

  let createdAt: Date

  /// Whether this session owns a dedicated backing worktree that Supacool
  /// created for it and should delete when the session itself is removed.
  var removeBackingWorktreeOnDelete: Bool

  /// User-marked "pay extra attention" bit.
  var isPriority: Bool

  /// Launches the agent in "plan mode" when the selected CLI supports it.
  /// Session-level for now: a session's primary terminal is the only one
  /// that respects this on spawn / rerun.
  var planMode: Bool

  /// User explicitly parked this session.
  var parked: Bool

  /// When true, the Auto-Observer monitors this session.
  var autoObserver: Bool

  /// Free-form instructions for the Auto-Observer.
  var autoObserverPrompt: String

  /// External work-item references parsed from the session's conversation.
  var references: [SessionReference]

  /// When the references list was last computed.
  var referencesScannedAt: Date?

  /// Non-nil when this session runs on a remote host.
  var remoteWorkspaceID: RemoteWorkspace.ID?

  /// Denormalized cache of `RemoteWorkspace.hostID`.
  var remoteHostID: RemoteHost.ID?

  /// Repository-linked remote target used to launch this session.
  var repositoryRemoteTargetID: RepositoryRemoteTarget.ID?

  /// Deterministic tmux session name used on the remote host.
  var tmuxSessionName: String?

  /// True when ssh to the remote host died and the user hasn't clicked
  /// Reconnect yet.
  var remoteConnectionLost: Bool

  /// User-pinned status that overrides the auto-classifier. Set via the
  /// card context menu when detection is wrong (e.g. card stuck "busy"
  /// while Claude is actually blocked on a question whose Notification
  /// payload didn't match our known prefixes). Auto-clears on the next
  /// definitive hook event (`updateSessionBusyState` transitions).
  /// Only applies while the tab exists; parked sessions ignore it.
  var manualStatusOverride: BoardSessionStatus?

  // MARK: Composition

  /// The terminals making up this session, in tab-strip order. Always at
  /// least one (the primary agent terminal). Additional `.shell` entries
  /// are the user's auxiliary tabs.
  var terminals: [SessionTerminal]

  /// Which terminal in `terminals` is the canonical agent — drives the
  /// board card's status, the displayName, the rerun/resume affordances.
  /// Defaults to `terminals[0].id` for new sessions.
  var primaryTerminalID: UUID

  /// Is this a remote session?
  var isRemote: Bool { remoteWorkspaceID != nil }

  init(
    id: UUID = UUID(),
    repositoryID: String,
    worktreeID: String,
    currentWorkspacePath: String? = nil,
    agent: AgentType?,
    initialPrompt: String,
    displayName: String? = nil,
    sourceBookmarkID: Bookmark.ID? = nil,
    debugSourceSessionID: AgentSession.ID? = nil,
    createdAt: Date = Date(),
    lastActivityAt: Date = Date(),
    hasCompletedAtLeastOnce: Bool = false,
    hasObservedInitialAgentEvent: Bool = false,
    lastKnownBusy: Bool = false,
    lastBusyTransitionAt: Date? = nil,
    removeBackingWorktreeOnDelete: Bool = false,
    isPriority: Bool = false,
    planMode: Bool = false,
    agentNativeSessionID: String? = nil,
    parked: Bool = false,
    autoObserver: Bool = false,
    autoObserverPrompt: String = "",
    references: [SessionReference] = [],
    referencesScannedAt: Date? = nil,
    remoteWorkspaceID: RemoteWorkspace.ID? = nil,
    remoteHostID: RemoteHost.ID? = nil,
    repositoryRemoteTargetID: RepositoryRemoteTarget.ID? = nil,
    tmuxSessionName: String? = nil,
    remoteConnectionLost: Bool = false,
    manualStatusOverride: BoardSessionStatus? = nil
  ) {
    self.id = id
    self.repositoryID = repositoryID
    self.worktreeID = worktreeID
    self.currentWorkspacePath = currentWorkspacePath ?? worktreeID
    self.displayName = displayName ?? Self.deriveDisplayName(from: initialPrompt, fallbackID: id)
    self.sourceBookmarkID = sourceBookmarkID
    self.debugSourceSessionID = debugSourceSessionID
    self.createdAt = createdAt
    self.removeBackingWorktreeOnDelete = removeBackingWorktreeOnDelete
    self.isPriority = isPriority
    self.planMode = planMode
    self.parked = parked
    self.autoObserver = autoObserver
    self.autoObserverPrompt = autoObserverPrompt
    self.references = references
    self.referencesScannedAt = referencesScannedAt
    self.remoteWorkspaceID = remoteWorkspaceID
    self.remoteHostID = remoteHostID
    self.repositoryRemoteTargetID = repositoryRemoteTargetID
    self.tmuxSessionName = tmuxSessionName
    self.remoteConnectionLost = remoteConnectionLost
    self.manualStatusOverride = manualStatusOverride

    let primary = SessionTerminal(
      id: id,
      role: agent == nil ? .shell : .agent,
      agent: agent,
      initialPrompt: initialPrompt,
      agentNativeSessionID: agentNativeSessionID,
      createdAt: createdAt,
      lastActivityAt: lastActivityAt,
      lastKnownBusy: lastKnownBusy,
      hasObservedInitialAgentEvent: hasObservedInitialAgentEvent,
      hasCompletedAtLeastOnce: hasCompletedAtLeastOnce,
      lastBusyTransitionAt: lastBusyTransitionAt
    )
    self.terminals = [primary]
    self.primaryTerminalID = primary.id
  }

  // Forward-compatible Codable — convention documented in
  // docs/agent-guides/persistence.md.
  //
  // Legacy single-terminal sessions (no `terminals` key) are migrated on
  // read: a single `.agent` (or `.shell`) terminal is synthesized from the
  // legacy top-level fields (`agent`, `initialPrompt`,
  // `agentNativeSessionID`, busy/idle flags, …). On the next save the file
  // is rewritten in the new shape; legacy keys are then dropped.
  enum CodingKeys: String, CodingKey {
    case id, repositoryID, worktreeID, currentWorkspacePath
    case displayName
    case sourceBookmarkID, debugSourceSessionID
    case createdAt
    case removeBackingWorktreeOnDelete, isPriority, planMode
    case parked
    case autoObserver, autoObserverPrompt
    case references, referencesScannedAt
    case remoteWorkspaceID, remoteHostID, repositoryRemoteTargetID
    case tmuxSessionName, remoteConnectionLost
    case manualStatusOverride

    // New shape
    case terminals, primaryTerminalID

    // Legacy single-terminal keys — read-only path, kept for migration.
    case agent, initialPrompt, agentNativeSessionID
    case lastActivityAt, lastKnownBusy, lastBusyTransitionAt
    case hasCompletedAtLeastOnce, hasObservedInitialAgentEvent
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(UUID.self, forKey: .id)
    repositoryID = try c.decode(String.self, forKey: .repositoryID)
    worktreeID = try c.decode(String.self, forKey: .worktreeID)
    currentWorkspacePath =
      try c.decodeIfPresent(String.self, forKey: .currentWorkspacePath) ?? worktreeID
    sourceBookmarkID = try c.decodeIfPresent(UUID.self, forKey: .sourceBookmarkID)
    debugSourceSessionID = try c.decodeIfPresent(UUID.self, forKey: .debugSourceSessionID)
    createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    removeBackingWorktreeOnDelete =
      try c.decodeIfPresent(Bool.self, forKey: .removeBackingWorktreeOnDelete) ?? false
    isPriority = try c.decodeIfPresent(Bool.self, forKey: .isPriority) ?? false
    planMode = try c.decodeIfPresent(Bool.self, forKey: .planMode) ?? false
    parked = try c.decodeIfPresent(Bool.self, forKey: .parked) ?? false
    autoObserver = try c.decodeIfPresent(Bool.self, forKey: .autoObserver) ?? false
    autoObserverPrompt = try c.decodeIfPresent(String.self, forKey: .autoObserverPrompt) ?? ""
    references = try c.decodeIfPresent([SessionReference].self, forKey: .references) ?? []
    referencesScannedAt = try c.decodeIfPresent(Date.self, forKey: .referencesScannedAt)
    remoteWorkspaceID = try c.decodeIfPresent(UUID.self, forKey: .remoteWorkspaceID)
    remoteHostID = try c.decodeIfPresent(UUID.self, forKey: .remoteHostID)
    repositoryRemoteTargetID = try c.decodeIfPresent(UUID.self, forKey: .repositoryRemoteTargetID)
    tmuxSessionName = try c.decodeIfPresent(String.self, forKey: .tmuxSessionName)
    remoteConnectionLost =
      try c.decodeIfPresent(Bool.self, forKey: .remoteConnectionLost) ?? false
    // `try?` (not `try`) so an unknown future case decodes to nil rather
    // than failing the whole record. Worst case: user's override silently
    // resets after a downgrade — acceptable.
    manualStatusOverride =
      try? c.decodeIfPresent(BoardSessionStatus.self, forKey: .manualStatusOverride)

    let storedDisplayName = try c.decodeIfPresent(String.self, forKey: .displayName)

    if let storedTerminals = try c.decodeIfPresent([SessionTerminal].self, forKey: .terminals),
       !storedTerminals.isEmpty {
      let resolvedPrimaryID =
        try c.decodeIfPresent(UUID.self, forKey: .primaryTerminalID) ?? storedTerminals[0].id
      let primaryPrompt =
        storedTerminals.first(where: { $0.id == resolvedPrimaryID })?.initialPrompt
          ?? storedTerminals[0].initialPrompt
      terminals = storedTerminals
      primaryTerminalID = resolvedPrimaryID
      displayName =
        storedDisplayName ?? Self.deriveDisplayName(from: primaryPrompt, fallbackID: id)
    } else {
      // Legacy: synthesize a single primary terminal from the old top-level fields.
      let legacyAgent = try c.decodeIfPresent(AgentType.self, forKey: .agent)
      let legacyInitialPrompt = try c.decodeIfPresent(String.self, forKey: .initialPrompt) ?? ""
      let legacyAgentNative =
        try c.decodeIfPresent(String.self, forKey: .agentNativeSessionID)
      let legacyLastKnownBusy =
        try c.decodeIfPresent(Bool.self, forKey: .lastKnownBusy) ?? false
      let legacyHasObservedInitial =
        try c.decodeIfPresent(Bool.self, forKey: .hasObservedInitialAgentEvent) ?? false
      let legacyHasCompletedOnce =
        try c.decodeIfPresent(Bool.self, forKey: .hasCompletedAtLeastOnce) ?? false
      let legacyLastActivity =
        try c.decodeIfPresent(Date.self, forKey: .lastActivityAt) ?? createdAt
      let legacyLastBusyTransition =
        try c.decodeIfPresent(Date.self, forKey: .lastBusyTransitionAt)

      let legacy = SessionTerminal(
        id: id,
        role: legacyAgent == nil ? .shell : .agent,
        agent: legacyAgent,
        initialPrompt: legacyInitialPrompt,
        agentNativeSessionID: legacyAgentNative,
        createdAt: createdAt,
        lastActivityAt: legacyLastActivity,
        lastKnownBusy: legacyLastKnownBusy,
        hasObservedInitialAgentEvent: legacyHasObservedInitial,
        hasCompletedAtLeastOnce: legacyHasCompletedOnce,
        lastBusyTransitionAt: legacyLastBusyTransition
      )
      terminals = [legacy]
      primaryTerminalID = id
      displayName =
        storedDisplayName ?? Self.deriveDisplayName(from: legacyInitialPrompt, fallbackID: id)
    }
  }

  // Encode emits only the new shape — the legacy keys are read-only.
  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(repositoryID, forKey: .repositoryID)
    try c.encode(worktreeID, forKey: .worktreeID)
    try c.encode(currentWorkspacePath, forKey: .currentWorkspacePath)
    try c.encode(displayName, forKey: .displayName)
    try c.encodeIfPresent(sourceBookmarkID, forKey: .sourceBookmarkID)
    try c.encodeIfPresent(debugSourceSessionID, forKey: .debugSourceSessionID)
    try c.encode(createdAt, forKey: .createdAt)
    try c.encode(removeBackingWorktreeOnDelete, forKey: .removeBackingWorktreeOnDelete)
    try c.encode(isPriority, forKey: .isPriority)
    try c.encode(planMode, forKey: .planMode)
    try c.encode(parked, forKey: .parked)
    try c.encode(autoObserver, forKey: .autoObserver)
    try c.encode(autoObserverPrompt, forKey: .autoObserverPrompt)
    try c.encode(references, forKey: .references)
    try c.encodeIfPresent(referencesScannedAt, forKey: .referencesScannedAt)
    try c.encodeIfPresent(remoteWorkspaceID, forKey: .remoteWorkspaceID)
    try c.encodeIfPresent(remoteHostID, forKey: .remoteHostID)
    try c.encodeIfPresent(repositoryRemoteTargetID, forKey: .repositoryRemoteTargetID)
    try c.encodeIfPresent(tmuxSessionName, forKey: .tmuxSessionName)
    try c.encode(remoteConnectionLost, forKey: .remoteConnectionLost)
    try c.encodeIfPresent(manualStatusOverride, forKey: .manualStatusOverride)
    try c.encode(terminals, forKey: .terminals)
    try c.encode(primaryTerminalID, forKey: .primaryTerminalID)
  }

  /// Pulls the first ~5 meaningful words from the prompt, title-cases them,
  /// and truncates to a short label. Falls back to "Session <short-id>".
  nonisolated static func deriveDisplayName(from prompt: String, fallbackID: UUID) -> String {
    let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return "Session " + String(fallbackID.uuidString.prefix(8))
    }
    let words = trimmed
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "_" })
      .prefix(5)
      .map(String.init)
    guard !words.isEmpty else {
      return "Session " + String(fallbackID.uuidString.prefix(8))
    }
    let candidate = words.joined(separator: " ")
    return String(candidate.prefix(60))
  }
}

// MARK: - Composition convenience

nonisolated extension AgentSession {
  /// The canonical agent terminal — the one that drives card status and
  /// is shown when the user taps the card. Falls back to the first
  /// terminal if `primaryTerminalID` is somehow stale.
  var primaryTerminal: SessionTerminal {
    terminals.first(where: { $0.id == primaryTerminalID }) ?? terminals[0]
  }

  /// All non-primary terminals (the shells / secondary agents that show
  /// up as auxiliary tabs in the session-scoped tab strip).
  var auxiliaryTerminals: [SessionTerminal] {
    terminals.filter { $0.id != primaryTerminalID }
  }

  /// Look up a terminal by id.
  func terminal(id: UUID) -> SessionTerminal? {
    terminals.first(where: { $0.id == id })
  }

  /// Mutate the primary terminal. Used by hook handlers and reducer paths
  /// where the implied target is the session's canonical agent.
  mutating func updatePrimaryTerminal(_ mutate: (inout SessionTerminal) -> Void) {
    guard let idx = terminals.firstIndex(where: { $0.id == primaryTerminalID }) else { return }
    mutate(&terminals[idx])
  }

  /// Mutate a specific terminal by id. Silently no-ops if no such terminal
  /// exists in this session.
  mutating func updateTerminal(id: UUID, _ mutate: (inout SessionTerminal) -> Void) {
    guard let idx = terminals.firstIndex(where: { $0.id == id }) else { return }
    mutate(&terminals[idx])
  }

  // MARK: Read-only forwarders to the primary terminal
  //
  // Kept so the broad surface of call sites that pre-date the composition
  // refactor (`session.agent`, `session.initialPrompt`,
  // `session.lastKnownBusy`, …) continue to compile and read the right
  // value. Writes MUST go through `updatePrimaryTerminal` (or
  // `updateTerminal(id:)`) so the move was meaningful.

  var agent: AgentType? { primaryTerminal.agent }
  var initialPrompt: String { primaryTerminal.initialPrompt }
  var agentNativeSessionID: String? { primaryTerminal.agentNativeSessionID }
  var lastKnownBusy: Bool { primaryTerminal.lastKnownBusy }
  var hasObservedInitialAgentEvent: Bool { primaryTerminal.hasObservedInitialAgentEvent }
  var hasCompletedAtLeastOnce: Bool { primaryTerminal.hasCompletedAtLeastOnce }
  var lastBusyTransitionAt: Date? { primaryTerminal.lastBusyTransitionAt }

  /// Newest activity across ALL terminals in the composition. Used by the
  /// board card's "Recently" timestamp and reference-scan staleness check.
  var lastActivityAt: Date {
    terminals.map(\.lastActivityAt).max() ?? createdAt
  }
}
