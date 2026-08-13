# Remote control — the embedded MCP server

Phase 1 of the remote-control plane: an MCP server running **inside the app
process** so an external agent (a Claude Code session on this Mac, later the
Claude phone app via a tunnel) can see and eventually drive the Matrix Board.
Plan history: `~/.claude/plans/supacool-mcp-control-plane.md`.

## Architecture

```
external MCP client (claude mcp add --transport http …)
  → MCPHTTPListener            loopback-only NWListener, minimal HTTP/1.1
  → StatelessHTTPServerTransport   (official modelcontextprotocol/swift-sdk 0.12.x)
      validation pipeline: OriginValidator.localhost → StaticBearerValidator
        → Accept/Content-Type/ProtocolVersion validators
  → MCP.Server (JSON-RPC dispatch)
  → MCPToolBox (@MainActor)    reads @Shared(.agentSessions), AppFeature store
                               state, WorktreeTerminalManager, TranscriptReader
```

- **`MCPControlServer`** (`@MainActor @Observable`) owns the assembly and a
  `status` (`stopped/starting/running/failed`) that Settings displays. Created
  in `SupacoolApp.init` after the app store; lives for the app's lifetime.
- **Lifecycle**: `MCPControlServer.startFollowingSettings()` (called once from
  `SupacoolApp.init`) consumes `$settingsFile.publisher.values` and
  starts/stops/restarts the server from
  `GlobalSettings.remoteControlServerEnabled` / `remoteControlServerPort`
  (default off / 4519). Deliberately **not** a window-bound sync view — a
  `.task`/`.onChange` on window content never fires when the window doesn't
  open (SwiftUI window restoration can keep it closed), and the control plane
  must run headless. Gotcha: don't put Combine operators (`.map`, etc.) on the
  `@Shared` publisher under default-MainActor isolation — the closure inherits
  MainActor but runs on Combine's thread and traps in
  `dispatch_assert_queue`; transform inside the `for await` loop instead.
- **`MCPHTTPListener`** is deliberately not a web server: loopback bind only,
  one request per connection (`Connection: close`), `Content-Length` bodies
  only, 16 KB header / 4 MB body caps, 60 s connection deadline. Parsing and
  serialization are pure statics — unit-tested without sockets.
- **Auth**: 32-byte hex token at `~/.supacool/mcp-token` (0600), generated on
  first enable, compared constant-time by `StaticBearerValidator`. This is
  deliberately NOT the SDK's OAuth-shaped `BearerTokenValidator`. Plaintext
  file is acceptable while exposure is loopback-only; **revisit before any
  off-machine exposure** (Phase 3: Tailscale Serve/Funnel + Claude-app
  connector — the SDK has OAuth 2.1 hooks when needed).

## Status parity invariant

`list_sessions` must never disagree with the board. The card status derivation
was extracted from `BoardRootView` into **`BoardSessionClassifier`**
(terminal-manager activity + PR ball-court snapshots + reinitializing set);
both the view and `MCPToolBox` construct it from the same inputs. If you touch
status logic, touch the classifier — not either call site.

## Tool contract (evolve additively — remote agents parse this)

- `list_sessions()` → `{sessions: [{id, name, repositoryID, workspacePath,
  agent, status, isPriority, parked, isRemote, remoteConnectionLost,
  createdAt, lastActivityAt}]}` — `status` is the `BoardSessionStatus`
  raw value; timestamps ISO8601.
- `read_session(session_id, scope: "screen"|"scrollback" = "screen",
  transcript_tail: 0..200 = 0)` → `{session, screen?,
  screenUnavailableReason?, transcript?}`. `screen` nil ⇔ no live surface
  (detached/disconnected) ⇔ `screenUnavailableReason` present. Scrollback is
  tail-capped at 200k chars; transcript entries are flattened to
  `{kind, at, text, detail}` (see `MCPTranscriptEntry`).

Write tools (Phase 2a) — gated by `remoteControlServerAllowsWrites`
(Settings → Remote Control → "Allow write access", default off): hidden from
`tools/list` AND refused at call time, checked per request (no restart). All
return an `MCPActionReceipt {action, sessionID, note}` — writes are
fire-and-observe, the caller polls `list_sessions`/`read_session`:

- `send_input(session_id, text, submit = true, force = false)` — types into
  the session's **primary surface**. `submit: true` = `sendPrompt` (synthesized
  Enter, the proven PR-Pulse path — a trailing `\n` via `sendText` is swallowed
  by bracketed paste and never submits); `submit: false` = raw `sendText`.
  Guards: refused when the primary surface is dead/blank (resume first), and
  refused while the agent is working (`agentActivity` working/deferredWork or
  `lastKnownBusy`) unless `force`.
- `resume_session(session_id)` — routes exactly like the card buttons via
  `BoardResumeEligibility`: shell session → `restoreShellSessionLayout`;
  captured native id → `resumeDetachedSession` (with `focusOnComplete: false`
  so a remote resume never yanks the local UI into full-screen); otherwise the
  agent's resume picker. Receipt's `action` names the route taken.
- `rerun_session(session_id)` — fresh run of the original prompt
  (`rerunDetachedSession`); refused for shell sessions and live tabs.
- `start_session(repository, prompt, agent = "claude", branch?, name?,
  model?)` — the remote New Terminal. `branch` set → new worktree via
  `.newBranch` (branch collisions are pre-checked against
  `repository.worktrees` so a remote spawn fails fast instead of queueing the
  interactive conflict alert on an unattended Mac); absent → repo root.
  Dispatches `BoardFeature.remoteStartSessionRequested` →
  the same `beginLocalSpawn` the sheet/inbox use, with sheet-identical
  defaults (bypassPermissions from UserDefaults, fetch-origin from settings).
  Spawn is async — receipt carries the future session id; a failed spawn
  restores a draft pill on the board, so remote failures are never invisible.
  Callers are told not to blind-retry (duplicate-spawn risk).

Results carry the payload twice: pretty JSON in `content[0].text` and the same
object as `structuredContent`.

## Client setup

Settings → Remote Control has a copy-button for:

```
claude mcp add --transport http supacool http://127.0.0.1:4519/mcp \
  --header "Authorization: Bearer <token>"
```

Caveat: `claude mcp add` echoes the token to stdout
(anthropics/claude-code#60909).

## Testing

`supacodeTests/RemoteControl/`: listener parsing + a real-socket round trip
(`MCPHTTPListenerTests`), token file + validator + full-stack
initialize/tools-list with 401 coverage (`MCPControlServerAuthTests` — uses
`MCPControlServer.makeTransport`, the production pipeline), and tool fixtures
over seeded `@Shared(.agentSessions)` with `readScreenContentsOverride`
(`MCPToolsTests`). E2E by hand: `scripts/build-and-preview.sh` with
`remoteControlServerEnabled` patched into the sandbox settings, then curl
with the sandbox's token.

## Phase 3 outlook

Phases 2a (send_input / resume / rerun) and 2b (start_session) shipped —
the full remote loop exists: see the board, read a session, answer it, wake
it, or spawn new work. Phase 3 fronts the same endpoint with Tailscale
Serve/Funnel for the Claude-app custom connector, possibly switching to
`StatefulHTTPServerTransport` for server push; requires replacing the
plaintext token (SDK has OAuth 2.1 hooks).
