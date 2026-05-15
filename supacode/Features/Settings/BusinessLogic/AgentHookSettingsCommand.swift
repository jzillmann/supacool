nonisolated enum AgentHookSettingsCommand {
  /// Marker present in all current Supacool hook commands.
  /// `AgentHookCommandOwnership` uses this to identify managed commands.
  static let socketPathEnvVar = "SUPACOOL_SOCKET_PATH"

  /// Markers present in legacy Supacool hook commands (pre-socket).
  static let legacyCLIPathEnvVar = "SUPACOOL_CLI_PATH"
  static let legacyAgentHookMarker = "agent-hook"

  private static let envCheck =
    #"[ -n "${SUPACOOL_SOCKET_PATH:-}" ]"#
    + #" && [ -n "${SUPACOOL_WORKTREE_ID:-}" ]"#
    + #" && [ -n "${SUPACOOL_TAB_ID:-}" ]"#
    + #" && [ -n "${SUPACOOL_SURFACE_ID:-}" ]"#

  private static let ids =
    "$SUPACOOL_WORKTREE_ID $SUPACOOL_TAB_ID $SUPACOOL_SURFACE_ID"

  /// Sends `worktreeID tabID surfaceID 1|0 pid` over a Unix socket.
  /// `$PPID` is the PID of the shell Claude / Codex spawned to run this
  /// hook — which equals the agent process itself. The app tracks it so
  /// a 30s sweep can clear stale busy state if the agent crashes before
  /// a matching busy-off hook fires.
  static func busyCommand(active: Bool) -> String {
    let flag = active ? "1" : "0"
    let send =
      #"echo "\#(ids) \#(flag) $PPID""#
      + #" | /usr/bin/nc -U -w1 "$SUPACOOL_SOCKET_PATH""#
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

  /// Broken `preToolUseCommand` variants from before the missing-quote fix
  /// (the synthetic Notification JSON had `"message":Claude…"` instead of
  /// `"message":"Claude…"`, so the socket server failed to decode it and
  /// every AskUserQuestion / ExitPlanMode turn left the card stuck busy).
  /// Listed here so re-install replaces them rather than coexisting with
  /// the fixed command.
  static let historicalPreToolUseCommands: [String] = [
    brokenPreToolUseCommand(agent: "claude")
  ]

  private static func brokenPreToolUseCommand(agent: String) -> String {
    let blockingPatterns = [
      #"*'"tool_name":"AskUserQuestion"'*"#,
      #"*'"tool_name":"ExitPlanMode"'*"#,
    ].joined(separator: "|")
    let header = #"printf '%s \#(agent)\n' "\#(ids)""#
    let body =
      #"printf '%s\n' '{"hook_event_name":"Notification","message":"#
      + #"Claude is waiting for your input"}'"#
    let sendNotification =
      #"{ \#(header); \#(body); } | /usr/bin/nc -U -w1 "$SUPACOOL_SOCKET_PATH""#
    let sendBusy =
      #"echo "\#(ids) 1 $PPID""#
      + #" | /usr/bin/nc -U -w1 "$SUPACOOL_SOCKET_PATH""#
    let pipeline =
      #"{ input=$(cat); case "$input" in \#(blockingPatterns)) "#
      + #"\#(sendNotification) ;; *) \#(sendBusy) ;; esac; }"#
    return "\(envCheck) && \(pipeline) 2>/dev/null || true"
  }

  private static func legacyBusyCommand(active: Bool) -> String {
    let flag = active ? "1" : "0"
    let send =
      #"echo "\#(ids) \#(flag)""#
      + #" | /usr/bin/nc -U -w1 "$SUPACOOL_SOCKET_PATH""#
    return "\(envCheck) && \(send) 2>/dev/null || true"
  }

  /// Forwards the raw hook event JSON (from stdin) to the socket.
  /// Header: `worktreeID tabID surfaceID agent`.
  static func notificationCommand(agent: String) -> String {
    let send =
      #"{ printf '%s \#(agent)\n' "\#(ids)"; cat; }"#
      + #" | /usr/bin/nc -U -w1 "$SUPACOOL_SOCKET_PATH""#
    return "\(envCheck) && \(send) 2>/dev/null || true"
  }

  /// PreToolUse hook command that distinguishes blocking tools from
  /// regular ones.
  ///
  /// Stock `busyCommand(active: true)` marks the session busy regardless
  /// of which tool is about to run. That misclassifies tools that block
  /// for user input (AskUserQuestion, ExitPlanMode) — Claude is "busy"
  /// from its own perspective but actually waiting on the user, so the
  /// card stays on green/working until the user answers. With no
  /// follow-up Notification event for these tools, the auto-classifier
  /// has no way to recover.
  ///
  /// This command reads the PreToolUse JSON payload from stdin, matches
  /// `tool_name` against the blocking-tool list, and either:
  ///   - emits a synthetic Notification with body containing "waiting
  ///     for your input" (the awaiting-input keywords from B), so
  ///     `isAwaitingInputSignal` promotes the card to `.awaitingInput`
  ///   - falls back to the regular busy=1 line for non-blocking tools
  ///
  /// Pure shell, POSIX `case` + `printf`; no jq dependency.
  static func preToolUseCommand(agent: String) -> String {
    let blockingPatterns = [
      #"*'"tool_name":"AskUserQuestion"'*"#,
      #"*'"tool_name":"ExitPlanMode"'*"#,
    ].joined(separator: "|")
    let header = #"printf '%s \#(agent)\n' "\#(ids)""#
    // The opening quote on the message value lives at the end of the first
    // raw string (`message":""#` evaluates to `message":"`) — without it the
    // emitted JSON is malformed and the socket server silently drops every
    // synthetic Notification, leaving cards stuck on `.inProgress` whenever
    // a turn ends on AskUserQuestion / ExitPlanMode.
    let body =
      #"printf '%s\n' '{"hook_event_name":"Notification","message":""#
      + #"Claude is waiting for your input"}'"#
    let sendNotification =
      #"{ \#(header); \#(body); } | /usr/bin/nc -U -w1 "$SUPACOOL_SOCKET_PATH""#
    let sendBusy =
      #"echo "\#(ids) 1 $PPID""#
      + #" | /usr/bin/nc -U -w1 "$SUPACOOL_SOCKET_PATH""#
    let pipeline =
      #"{ input=$(cat); case "$input" in \#(blockingPatterns)) "#
      + #"\#(sendNotification) ;; *) \#(sendBusy) ;; esac; }"#
    return "\(envCheck) && \(pipeline) 2>/dev/null || true"
  }
}
