import ComposableArchitecture
import Foundation

private nonisolated let remoteSpawnLogger = SupaLogger("Supacool.RemoteSpawn")

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
///    remote, so `nc -U $SUPACOOL_SOCKET_PATH` from a remote-side hook
///    tunnels straight back to the Mac's `AgentHookSocketServer`. We
///    also pass `StreamLocalBindUnlink=yes` so a prior stale socket
///    doesn't block the new forward.
/// 3. **Bootstrap exports of the SUPACOOL_* tuple** — the same env vars
///    the local spawn path exports, embedded directly in the remote bash
///    bootstrap instead of SSH `SetEnv` so the flow does not depend on
///    remote `sshd_config AcceptEnv`. Notably `SUPACOOL_TAB_ID` and
///    `SUPACOOL_SURFACE_ID` match the Mac-side UUIDs, so hook payloads
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
  /// Explicit user / hostname / port / identity file copied from
  /// `RemoteHost.connection`. Ignored when `deferToSSHConfig == true`.
  /// When `deferToSSHConfig` is false but a field here is `nil`, we omit
  /// the corresponding `-p` / `-i` flag and let OpenSSH defaults apply.
  let user: String?
  let hostname: String?
  let port: Int?
  let identityFile: String?
  /// When `true`, the runtime invokes `ssh <sshAlias>` with no -p / -i /
  /// user@host overrides so OpenSSH resolves the connection itself. Used
  /// for ssh_config entries with ProxyJump / Match / %-token expansion
  /// we can't faithfully re-express from flat fields.
  let deferToSSHConfig: Bool
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

  init(
    sshAlias: String,
    user: String? = nil,
    hostname: String? = nil,
    port: Int? = nil,
    identityFile: String? = nil,
    deferToSSHConfig: Bool = true,
    remoteWorkingDirectory: String,
    remoteSocketPath: String,
    localSocketPath: String,
    tmuxSessionName: String,
    worktreeID: String,
    tabID: UUID,
    surfaceID: UUID,
    agentCommand: String?,
    agent: AgentType?
  ) {
    self.sshAlias = sshAlias
    self.user = user
    self.hostname = hostname
    self.port = port
    self.identityFile = identityFile
    self.deferToSSHConfig = deferToSSHConfig
    self.remoteWorkingDirectory = remoteWorkingDirectory
    self.remoteSocketPath = remoteSocketPath
    self.localSocketPath = localSocketPath
    self.tmuxSessionName = tmuxSessionName
    self.worktreeID = worktreeID
    self.tabID = tabID
    self.surfaceID = surfaceID
    self.agentCommand = agentCommand
    self.agent = agent
  }
}

extension RemoteSpawnClient: DependencyKey {
  static let liveValue = RemoteSpawnClient(
    sshInvocation: { invocation in
      // ssh expands `~/.supacool/ssh/%r@%h:%p` locally but won't create
      // the parent — first spawn on a clean machine fails the bind
      // with `unix_listener: cannot bind to path` otherwise.
      do {
        try SupacoolPaths.ensureSSHControlDirectoryExists()
      } catch {
        remoteSpawnLogger.warning(
          "Failed to create ssh ControlPath directory: \(error.localizedDescription)"
        )
      }
      return renderSSHInvocation(invocation)
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
  let reverseForward = "\(inv.remoteSocketPath):\(inv.localSocketPath)"

  var args: [String] = [
    "/usr/bin/ssh",
    "-tt",
    "-o", "ControlMaster=auto",
    "-o", "ControlPath=~/.supacool/ssh/%r@%h:%p",
    "-o", "ControlPersist=600",
    "-o", "StreamLocalBindUnlink=yes",
    "-R", reverseForward,
  ]

  if inv.deferToSSHConfig {
    args.append(inv.sshAlias)
  } else {
    if let port = inv.port {
      args += ["-p", String(port)]
    }
    if let identityFile = inv.identityFile, !identityFile.isEmpty {
      args += ["-i", expandTilde(in: identityFile)]
    }
    let hostname = inv.hostname ?? inv.sshAlias
    let target: String = {
      if let user = inv.user, !user.isEmpty { return "\(user)@\(hostname)" }
      return hostname
    }()
    args.append(target)
  }

  args.append(renderBootstrapCommand(invocation: inv))

  return args.map { remoteSpawnShellQuote($0) }.joined(separator: " ")
}

/// Expand a single leading `~` (or `~/`) to `$HOME`. We do this at
/// command-assembly time, not at import, so the stored value stays
/// portable across machines.
nonisolated func expandTilde(in path: String) -> String {
  guard path.hasPrefix("~") else { return path }
  let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
  if path == "~" { return home }
  if path.hasPrefix("~/") {
    return home + String(path.dropFirst(1))
  }
  // `~username/…` — leave as-is; ssh handles it server-side.
  return path
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
  return renderBootstrapCommand(script: script)
}

nonisolated func renderBootstrapCommand(invocation inv: RemoteSpawnInvocation) -> String {
  let script = renderBootstrapScript(invocation: inv)
  return renderBootstrapCommand(script: script)
}

private nonisolated func renderBootstrapCommand(script: String) -> String {
  let encoded = Data(script.utf8).base64EncodedString()
  // Decode and pipe into bash. `bash -s --` prevents `--` from being
  // interpreted as an option; we pass no positional args.
  return "echo \(encoded) | base64 -d | bash -s --"
}

/// Pure function, unit-tested directly. Runs inside the remote shell on
/// every spawn — idempotent on success, noisy-on-fatal-error on failure.
nonisolated func renderBootstrapScript(
  agentCommand: String?,
  agent: AgentType? = nil,
  environment: [(name: String, value: String)] = []
) -> String {
  let tmuxCommandPrefix =
    #"exec "$SUPACOOL_TMUX_BIN" new-session -A -s "$TMUX_SESSION" "#
    + #"-c "$SUPACOOL_WORKTREE_PATH" "${tmux_env[@]}""#
  let execCommand: String
  if let agentCommand, !agentCommand.isEmpty {
    // Pass through tmux so the agent is the foreground process in the
    // session. `--` separates tmux flags from the user's command.
    execCommand = "\(tmuxCommandPrefix) -- \(agentCommand)"
  } else {
    // No agent — plain login shell inside tmux.
    execCommand = tmuxCommandPrefix
  }

  let exports = renderBootstrapExports(environment)
  let tmuxEnvironment = renderTmuxEnvironment(environment)

  // Hook install runs BEFORE exec — silent skip when python3 isn't on
  // the remote. Shell sessions skip entirely (nothing to hook).
  let hookInstall = agent.flatMap { RemoteHookInstaller.bootstrapSnippet(for: $0) } ?? ""

  return """
    set -e
    SUPACOOL_PATH_PREFIX="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin"
    SUPACOOL_PATH_PREFIX="$SUPACOOL_PATH_PREFIX:/opt/local/bin:$HOME/.local/bin:$HOME/bin"
    export PATH="$SUPACOOL_PATH_PREFIX:$PATH"
    \(exports)
    SUPACOOL_TMUX_BIN="$(command -v tmux || true)"
    if [ -z "$SUPACOOL_TMUX_BIN" ]; then
      echo "[supacool] Remote sessions require tmux, but tmux was not found on the remote PATH." >&2
      echo "[supacool] PATH=$PATH" >&2
      echo "[supacool] Install tmux on the remote host." >&2
      echo "[supacool] macOS: brew install tmux; Ubuntu/Debian: sudo apt install tmux." >&2
      exit 127
    fi
    mkdir -p ~/.supacool/hooks ~/.supacool/ssh
    # Fall back when the remote doesn't have the custom terminfo installed.
    if ! infocmp xterm-ghostty >/dev/null 2>&1; then
      export TERM=xterm-256color
    fi
    \(tmuxEnvironment)
    \(hookInstall)
    \(execCommand)
    """
}

nonisolated func renderBootstrapScript(invocation inv: RemoteSpawnInvocation) -> String {
  renderBootstrapScript(
    agentCommand: inv.agentCommand,
    agent: inv.agent,
    environment: bootstrapEnvironment(for: inv)
  )
}

private nonisolated func bootstrapEnvironment(
  for inv: RemoteSpawnInvocation
) -> [(name: String, value: String)] {
  [
    ("SUPACOOL_WORKTREE_ID", percentEncodeRemoteHookID(inv.worktreeID)),
    ("SUPACOOL_TAB_ID", inv.tabID.uuidString.lowercased()),
    ("SUPACOOL_SURFACE_ID", inv.surfaceID.uuidString.lowercased()),
    ("SUPACOOL_SOCKET_PATH", inv.remoteSocketPath),
    ("SUPACOOL_WORKTREE_PATH", inv.remoteWorkingDirectory),
    ("SUPACOOL_ROOT_PATH", inv.remoteWorkingDirectory),
    ("TMUX_SESSION", inv.tmuxSessionName),
  ]
}

private nonisolated func percentEncodeRemoteHookID(_ value: String) -> String {
  let allowedCharacters = CharacterSet.urlPathAllowed.subtracting(.init(charactersIn: "/"))
  return value.addingPercentEncoding(withAllowedCharacters: allowedCharacters) ?? value
}

private nonisolated func renderBootstrapExports(
  _ environment: [(name: String, value: String)]
) -> String {
  environment
    .map { "export \($0.name)=\(remoteSpawnShellQuote($0.value))" }
    .joined(separator: "\n")
}

private nonisolated func renderTmuxEnvironment(
  _ environment: [(name: String, value: String)]
) -> String {
  guard !environment.isEmpty else { return "tmux_env=()" }
  let entries = environment
    .map { "  -e \"\($0.name)=$\($0.name)\"" }
    .joined(separator: "\n")
  return """
    tmux_env=(
    \(entries)
    )
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

private nonisolated func isShellSafeChar(_ character: Character) -> Bool {
  if character.isLetter || character.isNumber { return true }
  return "_@%+=:,./-".contains(character)
}
