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

## Phase 2/3 outlook

Phase 2 adds write tools (`send_input` via the proven synthesized-Enter path,
`start_session`, `resume_session`) — same server, new tools; gate them behind
a separate settings toggle. Phase 3 fronts the same endpoint with Tailscale
Serve/Funnel for the Claude-app custom connector, possibly switching to
`StatefulHTTPServerTransport` for server push.
