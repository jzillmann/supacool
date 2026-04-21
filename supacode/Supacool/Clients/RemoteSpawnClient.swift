import ComposableArchitecture
import Foundation

/// Builds the ssh command string that Ghostty runs to bring up a remote
/// tmux session. All logic is pure string assembly so it's unit-testable
/// without actually shelling out; the `DependencyKey.liveValue` is the
/// same struct, just wired for injection.
///
/// The invocation relies on three things working together:
///
/// 1. **ControlMaster** — `-o ControlMaster=auto` + a per-host
///    `ControlPath` under `~/.supacool/ssh/` lets follow-up scp / extra
///    sessions reuse the same TCP connection. PR 3's screenshot upload
///    will lean on this.
/// 2. **Reverse Unix-socket forwarding** — `-R <remoteSock>:<localSock>`
///    publishes the Mac's agent-hook socket at a known path on the
///    remote, so `nc -U $SUPACODE_SOCKET_PATH` from a remote-side hook
///    tunnels straight back to the Mac's `AgentHookSocketServer`. We
///    also pass `StreamLocalBindUnlink=yes` so a prior stale socket
///    doesn't block the new forward.
/// 3. **SetEnv of the SUPACODE_* tuple** — the same env vars the local
///    spawn path exports. Notably `SUPACODE_TAB_ID` and
///    `SUPACODE_SURFACE_ID` match the Mac-side UUIDs, so hook payloads
///    are parse-identical to local ones and the existing classifier
///    needs no change.
nonisolated struct RemoteSpawnClient: Sendable {
  /// Returns the full command Ghostty should run as the tab's `command`.
  /// No shell wrapping — Ghostty executes the string as argv[0] + args,
  /// so we assemble the argv list ourselves and return the rendered form.
  var sshInvocation: @Sendable (RemoteSpawnInvocation) -> String
}

nonisolated struct RemoteSpawnInvocation: Equatable, Sendable {
  let sshAlias: String
  /// Absolute path on the remote host — where tmux starts.
  let remoteWorkingDirectory: String
  /// Absolute path on the remote to use as the reverse-tunnel's
  /// server-side socket. Must live in a user-writable location.
  let remoteSocketPath: String
  /// Absolute path to the local Unix socket `AgentHookSocketServer` is
  /// listening on.
  let localSocketPath: String
  /// Stable across reconnects so `tmux new-session -A` re-attaches.
  let tmuxSessionName: String
  /// Mac-side identifiers used by hook payloads. Match 1:1 with the
  /// UUIDs the local classifier keys by.
  let worktreeID: String
  let tabID: UUID
  let surfaceID: UUID
  /// What to exec inside the tmux session. `nil` drops into a login
  /// shell. For claude / codex, pass the full CLI invocation (e.g.
  /// `"claude code --resume <id>"`).
  let agentCommand: String?
  /// When set, the bootstrap runs a merge snippet that installs
  /// Supacool's progress + notification hooks into the remote agent's
  /// config before exec. Leave `nil` for shell sessions (nothing to
  /// hook) — the session still spawns, the board just won't light up.
  let agent: AgentType?
}

extension RemoteSpawnClient: DependencyKey {
  static let liveValue = RemoteSpawnClient(
    sshInvocation: { invocation in
      renderSSHInvocation(invocation)
    }
  )

  static let testValue = RemoteSpawnClient(
    sshInvocation: renderSSHInvocation  // deterministic, safe to share
  )
}

extension DependencyValues {
  var remoteSpawnClient: RemoteSpawnClient {
    get { self[RemoteSpawnClient.self] }
    set { self[RemoteSpawnClient.self] = newValue }
  }
}

// MARK: - ssh command assembly

/// Assembles the full `ssh` argv as a single shell-quoted command string.
/// Ghostty's surface config takes a command string — it spawns `/bin/sh`
/// to run it unless the command starts with a path to an executable, so
/// we shell-quote every argument that might contain special chars.
nonisolated func renderSSHInvocation(_ inv: RemoteSpawnInvocation) -> String {
  let setEnvPairs = [
    "SUPACODE_WORKTREE_ID=\(inv.worktreeID)",
    "SUPACODE_TAB_ID=\(inv.tabID.uuidString.lowercased())",
    "SUPACODE_SURFACE_ID=\(inv.surfaceID.uuidString.lowercased())",
    "SUPACODE_SOCKET_PATH=\(inv.remoteSocketPath)",
    "SUPACODE_WORKTREE_PATH=\(inv.remoteWorkingDirectory)",
    "SUPACODE_ROOT_PATH=\(inv.remoteWorkingDirectory)",
    "TMUX_SESSION=\(inv.tmuxSessionName)",
  ]

  let reverseForward = "\(inv.remoteSocketPath):\(inv.localSocketPath)"

  var args: [String] = [
    "/usr/bin/ssh",
    "-tt",
    "-o", "ControlMaster=auto",
    "-o", "ControlPath=~/.supacool/ssh/%r@%h:%p",
    "-o", "ControlPersist=600",
    "-o", "StreamLocalBindUnlink=yes",
    "-R", reverseForward,
    "-o", "SetEnv=\(setEnvPairs.joined(separator: " "))",
    inv.sshAlias,
    renderBootstrapCommand(agentCommand: inv.agentCommand, agent: inv.agent),
  ]

  return args.map { remoteSpawnShellQuote($0) }.joined(separator: " ")
}

/// The single-line shell command the remote shell runs. Keeps the Mac
/// side free of heredoc quoting gymnastics: we base64-embed a small
/// bootstrap script and the remote decodes + execs it with `bash -s`.
/// Invariant: exactly one set of single quotes around the whole thing,
/// since the enclosing ssh arg is shell-escaped once by `renderSSHInvocation`.
nonisolated func renderBootstrapCommand(
  agentCommand: String?,
  agent: AgentType? = nil
) -> String {
  let script = renderBootstrapScript(agentCommand: agentCommand, agent: agent)
  let encoded = Data(script.utf8).base64EncodedString()
  // Decode and pipe into bash. `bash -s --` prevents `--` from being
  // interpreted as an option; we pass no positional args.
  return "echo \(encoded) | base64 -d | bash -s --"
}

/// Pure function, unit-tested directly. Runs inside the remote shell on
/// every spawn — idempotent on success, noisy-on-fatal-error on failure.
nonisolated func renderBootstrapScript(
  agentCommand: String?,
  agent: AgentType? = nil
) -> String {
  let execCommand: String
  if let agentCommand, !agentCommand.isEmpty {
    // Pass through tmux so the agent is the foreground process in the
    // session. `--` separates tmux flags from the user's command.
    execCommand = "exec tmux new-session -A -s \"$TMUX_SESSION\" -c \"$SUPACODE_WORKTREE_PATH\" -- \(agentCommand)"
  } else {
    // No agent — plain login shell inside tmux.
    execCommand = "exec tmux new-session -A -s \"$TMUX_SESSION\" -c \"$SUPACODE_WORKTREE_PATH\""
  }

  // Hook install runs BEFORE exec — silent skip when python3 isn't on
  // the remote. Shell sessions skip entirely (nothing to hook).
  let hookInstall = agent.flatMap { RemoteHookInstaller.bootstrapSnippet(for: $0) } ?? ""

  return """
    set -e
    mkdir -p ~/.supacool/hooks ~/.supacool/ssh
    # Stale-socket belt: if a prior ssh crashed, the reverse-forward unlink
    # may have failed; rm -f makes the bind idempotent.
    rm -f "$SUPACODE_SOCKET_PATH" 2>/dev/null || true
    # Fall back when the remote doesn't have the custom terminfo installed.
    if ! infocmp xterm-ghostty >/dev/null 2>&1; then
      export TERM=xterm-256color
    fi
    \(hookInstall)
    \(execCommand)
    """
}

/// Single-quote-wrap a string for safe use in the shell command line we
/// hand to Ghostty. Any embedded single quote is replaced with the
/// canonical `'\''` sequence.
nonisolated func remoteSpawnShellQuote(_ value: String) -> String {
  if value.isEmpty { return "''" }
  if value.allSatisfy(isShellSafeChar) { return value }
  let escaped = value.replacingOccurrences(of: "'", with: #"'\''"#)
  return "'\(escaped)'"
}

private nonisolated func isShellSafeChar(_ ch: Character) -> Bool {
  if ch.isLetter || ch.isNumber { return true }
  return "_@%+=:,./-".contains(ch)
}
