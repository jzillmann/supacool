import Foundation

private nonisolated let remoteHookLogger = SupaLogger("Supacool.RemoteHooks")

nonisolated enum RemoteHookInstallerError: Error {
  /// Agent has no Supacool-known hook protocol — any user-defined custom
  /// agent today. The bootstrap snippet is silently omitted; the remote
  /// session still spawns and falls back to screen-fingerprint polling.
  case noHookProtocol(agentID: String)
}

/// Builds the shell snippet embedded into `renderBootstrapScript` that
/// idempotently merges Supacool's agent hooks into the remote's
/// claude / codex config. Without this, the reverse socket tunnel has
/// nothing firing into it — the agent never invokes
/// `nc -U $SUPACOOL_SOCKET_PATH` because its own config doesn't know
/// about the hooks.
///
/// Design choices:
/// - **Python3** for the merge, not `jq`. Python's on every modern
///   Linux dev box by default; jq isn't. Both local and remote config
///   files are JSON so the merge logic is 30 short lines.
/// - **Merge, not replace.** We append our hook groups to each event's
///   array rather than overwriting — preserves any hooks the user has
///   already set up by hand. Idempotency is handled by filtering out
///   pre-existing groups whose sole command matches ours.
/// - **Silent skip** when python3 is unavailable: the remote session
///   still spawns, the board just doesn't light up with busy/
///   awaiting-input for that session. Logged in the remote shell's
///   stderr so a curious user can investigate.
nonisolated enum RemoteHookInstaller {
  /// Serializes Supacool's hook groups for `agent` into a single JSON
  /// blob keyed by event, then returns a shell snippet that merges it
  /// into the remote agent's config file. Pi uses a TypeScript extension
  /// instead of settings.json hooks. Returns `nil` for agents with no hook
  /// protocol Supacool installs (user-defined entries) — the session still
  /// bootstraps without the hook merge step.
  static func bootstrapSnippet(for agent: AgentType) -> String? {
    if agent.id == "pi" {
      return renderPiExtensionSnippet()
    }
    do {
      let hooks = try allHookGroups(for: agent)
      guard let configPath = remoteConfigPath(for: agent) else { return nil }
      return try renderSnippet(hooks: hooks, configPath: configPath)
    } catch RemoteHookInstallerError.noHookProtocol(let id) {
      remoteHookLogger.info("No remote hook protocol for agent id=\(id); skipping install.")
      return nil
    } catch {
      remoteHookLogger.warning("Failed to build remote hook snippet: \(error)")
      return nil
    }
  }

  /// Combines progress + notification hook groups for the agent. Events
  /// that appear in both (e.g. Claude's `Stop` fires both busy-off and
  /// the notification forwarder) are concatenated into a single array so
  /// the merge is a flat append per event. Throws `noHookProtocol` for
  /// agents Supacool has no hook installer for.
  fileprivate static func allHookGroups(for agent: AgentType) throws -> [String: [JSONValue]] {
    let sources: [[String: [JSONValue]]]
    switch agent.id {
    case "claude":
      sources = [
        try ClaudeHookSettings.progressHookGroupsByEvent(),
        try ClaudeHookSettings.notificationHookGroupsByEvent(),
      ]
    case "codex":
      sources = [
        try CodexHookSettings.progressHookGroupsByEvent(),
        try CodexHookSettings.notificationHookGroupsByEvent(),
      ]
    default:
      throw RemoteHookInstallerError.noHookProtocol(agentID: agent.id)
    }
    var result: [String: [JSONValue]] = [:]
    for source in sources {
      for (event, groups) in source {
        result[event, default: []].append(contentsOf: groups)
      }
    }
    return result
  }

  fileprivate static func remoteConfigPath(for agent: AgentType) -> String? {
    switch agent.id {
    case "claude": "$HOME/.claude/settings.json"
    case "codex": "$HOME/.codex/hooks.json"
    default: nil
    }
  }

  /// Returns a bash snippet that idempotently installs Supacool's Pi
  /// extension into Pi's global auto-discovery directory on the remote.
  fileprivate static func renderPiExtensionSnippet() -> String {
    let encoded = Data(PiSettingsInstaller.extensionSource.utf8).base64EncodedString()
    return """
      # Supacool Pi extension install — Pi has no settings.json hook
      # protocol, so install a tiny extension that forwards lifecycle
      # events to the reverse-forwarded Supacool socket.
      if command -v base64 >/dev/null 2>&1; then
        mkdir -p "$HOME/.pi/agent/extensions"
        SUPACOOL_PI_EXTENSION_B64=\(encoded) \
          sh -c 'printf %s "$SUPACOOL_PI_EXTENSION_B64" | base64 -d \
            > "$HOME/.pi/agent/extensions/\(PiSettingsInstaller.extensionFileName)"' || true
      else
        echo "[supacool] base64 not found on remote; skipping Pi extension install" >&2
      fi
      """
  }

  /// Returns a bash snippet that writes `$HOOK_JSON`, ensures the parent
  /// dir exists, then invokes embedded python3 to merge. Exits 0 in all
  /// paths (skip-on-error) so a python-less host doesn't kill the tmux
  /// bootstrap.
  fileprivate static func renderSnippet(
    hooks: [String: [JSONValue]],
    configPath: String
  ) throws -> String {
    let hookObject: JSONValue = .object(["hooks": .object(hooks.mapValues(JSONValue.array))])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(hookObject)
    let encoded = data.base64EncodedString()

    return """
      # Supacool hook install — merges busy/notify hooks into the remote
      # agent's config so they actually fire into the reverse-forwarded
      # socket. Silent skip on missing python3 or malformed existing file.
      if command -v python3 >/dev/null 2>&1; then
        SUPACOOL_HOOK_CONFIG_PATH="\(configPath)"
        mkdir -p "$(dirname "$SUPACOOL_HOOK_CONFIG_PATH")"
        SUPACOOL_HOOK_B64=\(encoded) python3 - "$SUPACOOL_HOOK_CONFIG_PATH" <<'SUPACOOL_HOOK_PYEOF' || true
      import base64, json, os, sys
      path = sys.argv[1]
      ours = json.loads(base64.b64decode(os.environ["SUPACOOL_HOOK_B64"]))
      try:
          with open(path) as f:
              existing = json.load(f)
      except (FileNotFoundError, json.JSONDecodeError):
          existing = {}
      if not isinstance(existing, dict):
          existing = {}
      hooks = existing.setdefault("hooks", {}) if isinstance(existing.get("hooks", {}), dict) else {}
      existing["hooks"] = hooks
      # Collect the command strings our hooks define so we can prune any
      # prior Supacool-installed groups before appending fresh ones.
      our_cmds = set()
      for groups in ours["hooks"].values():
          for group in groups:
              for h in group.get("hooks", []):
                  if "command" in h:
                      our_cmds.add(h["command"])
      for event, our_groups in ours["hooks"].items():
          cur = hooks.get(event, [])
          if not isinstance(cur, list):
              cur = []
          # Drop any pre-existing group that contains ONLY our commands —
          # keeps reconnects from stacking duplicates over time.
          pruned = []
          for group in cur:
              cmds = [h.get("command") for h in group.get("hooks", []) if isinstance(h, dict)]
              if cmds and all(c in our_cmds for c in cmds):
                  continue
              pruned.append(group)
          hooks[event] = pruned + our_groups
      tmp = path + ".supacool.tmp"
      with open(tmp, "w") as f:
          json.dump(existing, f, indent=2, sort_keys=True)
      os.replace(tmp, path)
      SUPACOOL_HOOK_PYEOF
      else
        echo "[supacool] python3 not found on remote; skipping hook install" >&2
      fi
      """
  }
}
