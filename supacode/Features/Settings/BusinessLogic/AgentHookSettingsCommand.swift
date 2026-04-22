nonisolated enum AgentHookSettingsCommand {
  /// Marker present in all current Supacode hook commands.
  /// `AgentHookCommandOwnership` uses this to identify managed commands.
  static let socketPathEnvVar = "SUPACODE_SOCKET_PATH"

  /// Markers present in legacy Supacode hook commands (pre-socket).
  static let legacyCLIPathEnvVar = "SUPACODE_CLI_PATH"
  static let legacyAgentHookMarker = "agent-hook"

  private static let envCheck =
    #"[ -n "${SUPACODE_SOCKET_PATH:-}" ]"#
    + #" && [ -n "${SUPACODE_WORKTREE_ID:-}" ]"#
    + #" && [ -n "${SUPACODE_TAB_ID:-}" ]"#
    + #" && [ -n "${SUPACODE_SURFACE_ID:-}" ]"#

  private static let ids =
    "$SUPACODE_WORKTREE_ID $SUPACODE_TAB_ID $SUPACODE_SURFACE_ID"

  /// Sends `worktreeID tabID surfaceID 1|0 pid` over a Unix socket.
  /// `$PPID` is the PID of the shell Claude / Codex spawned to run this
  /// hook — which equals the agent process itself. The app tracks it so
  /// a 30s sweep can clear stale busy state if the agent crashes before
  /// a matching busy-off hook fires.
  static func busyCommand(active: Bool) -> String {
    let flag = active ? "1" : "0"
    let send =
      #"echo "\#(ids) \#(flag) $PPID""#
      + #" | /usr/bin/nc -U -w1 "$SUPACODE_SOCKET_PATH""#
    return "\(envCheck) && \(send) 2>/dev/null || true"
  }

  /// Pre-PID busy command strings. On re-install these get pruned so a
  /// pre-upgrade settings.json doesn't end up with both the old and new
  /// busy commands firing for every event. Only the two are ever needed
  /// because `busyCommand` has exactly two possible outputs.
  static let historicalBusyCommands: [String] = [
    legacyBusyCommand(active: true),
    legacyBusyCommand(active: false),
  ]

  private static func legacyBusyCommand(active: Bool) -> String {
    let flag = active ? "1" : "0"
    let send =
      #"echo "\#(ids) \#(flag)""#
      + #" | /usr/bin/nc -U -w1 "$SUPACODE_SOCKET_PATH""#
    return "\(envCheck) && \(send) 2>/dev/null || true"
  }

  /// Forwards the raw hook event JSON (from stdin) to the socket.
  /// Header: `worktreeID tabID surfaceID agent`.
  static func notificationCommand(agent: String) -> String {
    let send =
      #"{ printf '%s \#(agent)\n' "\#(ids)"; cat; }"#
      + #" | /usr/bin/nc -U -w1 "$SUPACODE_SOCKET_PATH""#
    return "\(envCheck) && \(send) 2>/dev/null || true"
  }
}
