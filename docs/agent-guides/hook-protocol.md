# Agent hook protocol — how busy state and notifications reach the board

Every card state transition on the Matrix Board (Working / Waiting / Starting) and every
Resume affordance ultimately comes from this protocol. It is referenced all over the
codebase but was previously specified nowhere; this is the wire contract. Read before
touching busy-state, card classification, notifications, session-id capture, or hook
installation (local or remote).

## Big picture

```
claude / codex / pi process (inside a Supacool terminal, local or via ssh+tmux)
  └─ agent fires a lifecycle hook (UserPromptSubmit, Stop, Notification, …)
      └─ hook command: echo "<ids> …" | nc -U $SUPACOOL_SOCKET_PATH
          └─ AgentHookSocketServer (Unix domain socket, one per app process)
              ├─ onBusy         → WorktreeTerminalManager busy flags → card buckets
              └─ onNotification → system notification + captureAgentNativeSessionID
                                   (session_id → @Shared(.agentSessions) → Resume)
```

The agent side is deliberately dumb: a `printf`/`echo` piped through `/usr/bin/nc -U -w1`.
No CLI binary, no dependencies beyond `nc`, works identically over the ssh reverse-forward.

## The socket

`AgentHookSocketServer` (`supacode/Infrastructure/AgentHookSocketServer.swift`) listens on

```
/tmp/supacool-<uid>/pid-<app pid>
```

- Directory is `0o700`; one socket per running app process.
- On startup, stale `pid-*` files whose process no longer exists (`kill(pid, 0)` probe)
  are pruned, so crashed instances don't accumulate sockets.

## Environment variables

Injected into every terminal Supacool spawns (`WorktreeTerminalState`, ~line 1284) and
exported by the remote bootstrap script (`RemoteSpawnClient`):

| Variable | Meaning |
|---|---|
| `SUPACOOL_SOCKET_PATH` | Path to the app's hook socket (remote: the reverse-forwarded socket) |
| `SUPACOOL_WORKTREE_ID` | `Worktree.ID` (directory path), **percent-encoded** so it survives whitespace |
| `SUPACOOL_TAB_ID` | The terminal tab UUID == `SessionTerminal.id` |
| `SUPACOOL_SURFACE_ID` | The Ghostty surface UUID |
| `SUPACOOL_WORKTREE_PATH` / `SUPACOOL_ROOT_PATH` / `SUPACOOL_REPOSITORY_PATH` | Plain paths for user scripts (`supacode/Domain/Worktree.swift`); not part of the hook wire format |
| `SUPACOOL_REPO_ROOT` / `SUPACOOL_WORKTREE_ROOT` | Same idea, injected by `WorktreeTerminalState` for repo setup scripts (the pair the README documents); not part of the hook wire format |

Hook commands guard on the first four being non-empty and no-op otherwise (`|| true`), so
running an agent outside Supacool is harmless.

## Wire format

Two message shapes, newline-framed (parser in `AgentHookSocketServer`):

**Busy flag** — flips the per-tab busy bit:

```
<worktreeID> <tabID> <surfaceID> <0|1> [<pid>]\n
```

The optional 5th field is `$PPID` of the hook shell — i.e. the agent process itself.
Supacool tracks it so a ~30 s sweep (`AgentPIDSweep`) can clear busy state if the agent
crashes before its busy-off hook fires. Pre-upgrade hook installs omit the field; the
parser tolerates both.

**Notification** — two lines, header then JSON payload:

```
<worktreeID> <tabID> <surfaceID> <agent>\n
{"hook_event_name": "...", "title": ..., "message": ..., "last_assistant_message": ..., "session_id": ...}\n
```

Parsed into `AgentHookNotification { agent, event, title, body, sessionID }`. The
`session_id` is the agent-native conversation id (Claude Code's `session_id`) — capturing
it is what makes **Resume** possible after a relaunch.

## Hook installation (local)

`AgentHookSettingsFileInstaller` writes managed hook commands into each agent's own
config (Claude's `settings.json`, Codex's config). Command strings are built by
`AgentHookSettingsCommand` (`supacode/Features/Settings/BusinessLogic/`); the
`SUPACOOL_SOCKET_PATH` marker identifies commands we own (`AgentHookCommandOwnership`),
and known-broken historical variants are pruned on re-install rather than left to fire
alongside the fixed ones.

Event wiring (see `ClaudeHookSettings` / `CodexHookSettings` for the current truth):

- **busy on**: `UserPromptSubmit`, `PreToolUse`. PreToolUse matters — it's the only hook
  that fires when the agent resumes after a permission grant.
- **busy off**: `Stop`, `SessionEnd`, `PostToolUseFailure`.
- **PreToolUse special case**: blocking tools (`AskUserQuestion`, `ExitPlanMode`) emit a
  synthetic *Notification* ("Claude is waiting for your input") instead of busy-on, so the
  card flips to Waiting rather than Working.
- **Notification hooks** forward the agent's JSON payload verbatim (that's where
  `session_id` rides along).
- Codex mirrors the Claude wiring with an explicit Bash matcher on PreToolUse; pi is
  handled via a pi extension.

## Remote sessions (ssh + tmux)

The same protocol crosses the wire via an SSH reverse forward
(`-R <remoteSock>:<localSock>`, with `StreamLocalBindUnlink=yes`), so a remote-side hook
does the *identical* `nc -U $SUPACOOL_SOCKET_PATH`. Key choices (details and rationale in
`RemoteSpawnClient.swift` and [`remote-hosts.md`](./remote-hosts.md)):

- The bootstrap script **exports the `SUPACOOL_*` tuple itself** instead of SSH `SetEnv`,
  because `AcceptEnv` allow-lists silently drop the vars on default sshd installs.
- `SUPACOOL_TAB_ID` / `SUPACOOL_SURFACE_ID` match the Mac-side UUIDs, so remote payloads
  route through the exact same `onBusy`/`onNotification` paths — the board can't tell
  local from remote.
- `RemoteHookInstaller` installs the hook config on the host (base64-encoded JSON merged
  via a python heredoc — env vars `SUPACOOL_HOOK_CONFIG_PATH`, `SUPACOOL_HOOK_B64`,
  `SUPACOOL_PI_EXTENSION_B64`).

## Consumption inside the app

`WorktreeTerminalManager.configureSocketServer` owns both callbacks:

- `onBusy` updates the per-tab busy flag; `BoardRootView.classify(_:)` reads it on every
  render to bucket cards (see [`architecture.md`](./architecture.md) § busy-state wiring
  and the card status classifier).
- `onNotification` posts the system notification and calls
  `captureAgentNativeSessionID(tabID:notification:)`.

### Deferred-work lease (intentional idle ≠ waiting on the user)

Claude can end its turn *on purpose* while something external runs — holding for CI, a
background poller, a timed re-check. The Stop hook body carries the agent's last message;
`isDeferredWorkSignal` matches it against a phrase list ("check back", "waiting on ci",
"poll pending", "background poller", "holding for", …) and, on match, takes a
**deferred-work lease** for the tab. While the lease is live, `classify` keeps the card
**In Progress** even though the busy bit is off.

- Lease duration: parsed from the body when it names one ("in ~7 min" → 7 min + 90 s
  buffer), else a 15-minute fallback TTL.
- Lease cleared by: any busy-on edge, any non-deferred Stop, a hard awaiting-input
  signal, or TTL expiry (at which point the card falls through to Waiting on
  External / Waiting on Me — a dead hold always resurfaces).

**Soft vs hard awaiting signals.** Claude's built-in idle reminder (`Notification`, body
exactly "Claude is waiting for your input", fires ~60 s after the prompt goes idle) is
*soft*: while a lease is active it is suppressed — otherwise every hold longer than a
minute got dumped into Waiting on Me (trace BF99621E). Permission / approval
notifications are *hard*: they always promote to `.awaitingInput` and release the lease.
Known caveat: the synthetic PreToolUse notification for blocking tools reuses the idle
reminder's exact body, so an AskUserQuestion asked as the very first tool call after a
deferred-work Stop is masked until the lease expires (bounded by the 15-min TTL; any
other tool call first clears the lease via its busy-on edge).

## Gotchas

- **Preview instances**: `scripts/preview-isolated.sh` strips inherited `SUPACOOL_*` vars
  so a preview launched from inside a Supacool terminal can't talk to the parent app's
  socket.
- **Why there's no "Ready vs Wants Input" bucket**: the protocol carries a busy bit and
  notifications, but no distinct "ready for review" event — that's the protocol extension
  [`out-of-scope.md`](./out-of-scope.md) refers to.
- **Tests**: `AgentHookSocketServerTests`, `AgentHookCommandTests`,
  `ClaudeProgressHookTests`, `CodexHookPayloadTests`, `AgentPIDSweepTests`,
  `RemoteHookInstallerTests`, `AwaitingInputSignalTests`, `DeferredWorkSignalTests`, and
  the deferred-work / awaiting cases in `WorktreeTerminalManagerTests` are the executable
  spec; extend them when you change any of the above.
