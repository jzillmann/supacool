# Architecture

This is how Supacool actually works. Read after `AGENTS.md`.

## The big picture

Supacool is a card-based view over supacode's existing terminal engine. Supacode gave us: `GhosttySurfaceView`, `WorktreeTerminalManager`, `TerminalClient`, the agent-busy hook protocol, TCA wiring. Supacool added: a different top-level UI (`BoardRootView`), a persistent session model (`AgentSession`), and a reducer (`BoardFeature`) that tracks sessions as first-class entities independent of the worktree tab bar.

Mental model shift from supacode:

| supacode | Supacool |
|---|---|
| `NavigationSplitView(sidebar:, detail:)` | `BoardRootView` (single window) |
| Sidebar lists worktrees; one terminal-set per worktree; tabs inside | Board lists **sessions**; each session is one tab in a (shared) worktree's state |
| Creating a terminal = creating a tab in the currently selected worktree | Creating a terminal = creating a session with a prompt, which creates a tab keyed by session ID |
| Busy/idle status is per-surface, shown as tab badges | Busy/idle moves the card between board sections |

## Data model

```
AgentSession (Codable, persisted)
├── id: UUID                       — session identity; ALSO the primary terminal's TerminalTabID
├── repositoryID: String           — Repository.ID (repo root path)
├── worktreeID: String             — Worktree.ID (directory path)
├── displayName: String            — user-editable, defaults to deriveDisplayName(primary prompt)
├── createdAt                      — Date (session-level)
├── isPriority / planMode / parked — session-scoped flags
├── autoObserver / autoObserverPrompt — session-scoped observer config
├── references / referencesScannedAt — work-item parse cache
├── remoteWorkspaceID / remoteHostID / tmuxSessionName / remoteConnectionLost — remote-session metadata
├── terminals: [SessionTerminal]   — the composition (always ≥ 1, see below)
└── primaryTerminalID: UUID        — which terminal drives card status; defaults to terminals[0].id

SessionTerminal (Codable, embedded in AgentSession.terminals)
├── id: UUID                       — the Ghostty TerminalTabID.rawValue
├── role: SessionTerminalRole      — .agent | .shell
├── agent: AgentType?              — nil for .shell
├── initialPrompt: String          — verbatim, used for Rerun
├── agentNativeSessionID: String?  — captured per terminal (claude's session_id); used for Resume
├── workingDirectoryHint: String?  — last observed cwd; spawned-into on restore
├── createdAt / lastActivityAt     — per-terminal Date
├── lastKnownBusy: Bool            — per-terminal persisted busy flag (drives .detached vs .interrupted)
├── hasObservedInitialAgentEvent   — flips true on first hook event from this terminal
├── hasCompletedAtLeastOnce        — flips true on first busy→idle of this terminal
└── lastBusyTransitionAt: Date?    — most recent busy-state flip (drives classifier hysteresis)
```

**Key invariant**: `session.id == session.primaryTerminalID == primaryTerminal.id == its Ghostty tab id`. Newly created sessions always satisfy this; the model permits decoupling in the future but no code path does so today. Don't break it casually.

`AgentSession` exposes read-only forwarders (`session.agent`, `session.initialPrompt`, `session.lastKnownBusy`, `session.lastActivityAt`, …) that delegate to the primary terminal so the broad read surface stays terse. Writes must go through `session.updatePrimaryTerminal { … }` or `session.updateTerminal(id:) { … }` — there are no setters on the forwarders. Status (in-progress / waiting on me) is derived from the PRIMARY terminal only; shells in the composition appear as a `+N sh` pill on the card but never promote status.

## State hierarchy (TCA)

```
AppFeature.State                    (supacode, modified)
├── repositories: RepositoriesFeature.State  (supacode — registered repos live here)
├── settings:     SettingsFeature.State      (supacode)
├── commandPalette, updates, etc.            (supacode)
└── board:        BoardFeature.State         (Supacool — adds this)
    ├── @Shared(.agentSessions)   sessions: [AgentSession]        → sessions/ dir on disk (see below)
    ├── @Shared(.boardFilters)    filters: BoardFilters           → board-filters.json
    ├── @Shared(.bookmarks)       bookmarks: [Bookmark]           → bookmarks.json
    ├── @Shared(.drafts)          drafts: [Draft]                 → drafts.json
    ├── @Shared(.trashedSessions) trashedSessions: [TrashedSession] → trashed-sessions.json
    ├── @Shared(.remoteHosts)     remoteHosts: [RemoteHost]       → remote-hosts.json
    ├── @Shared(.remoteWorkspaces) remoteWorkspaces: [RemoteWorkspace] → remote-workspaces.json
    ├── focusedSessionID: AgentSession.ID?   (transient — UI mode switch)
    ├── @Presents newTerminalSheet: NewTerminalFeature.State?     (prompt / agent / repo / worktree)
    ├── @Presents linearInbox:     LinearInboxFeature.State?      (Linear ticket inbox sheet)
    ├── @Presents debugSheet:      DebugSessionFeature.State?     ("Debug this session…" sheet)
    ├── @Presents worktreeJanitor: WorktreeJanitorFeature.State?  (worktree scan/prune, in trash dialog)
    └── plus transient sets/flags (reinitializing ids, auto-observer/auto-resume guards,
        getting-started state, trash sheet flag, …) — see BoardFeature.State doc comments
```

Four child reducers hang off `BoardFeature` via `@Presents` + `ifLet`; when you add a new sheet-shaped sub-domain, follow that pattern rather than inlining more actions into `BoardFeature` (it is already the largest reducer in the repo).

`RepositoriesFeature.State` continues to own the registered-repos list. `BoardFeature` doesn't duplicate it — instead, actions that need the list (`openNewTerminalSheet`, `rerunDetachedSession`, `resumeDetachedSession`) take `[Repository]` as a parameter, passed from the view.

## View hierarchy

```
ContentView                         (Supacool/App/)
└── BoardRootView                   (Supacool/Features/Board/Views/)
    ├── [focusedSessionID == nil] → BoardView
    │   ├── GettingStartedCarouselView   (first-run onboarding cards)
    │   ├── BookmarkPillRow / DraftPillRow  (spawn-from-bookmark, resume half-finished prompts)
    │   ├── SessionCardContainer (hover, busy-change observer)
    │   │   └── SessionCardView  (name, chips — repo status, footprint, PR status —, status)
    │   └── BoardTrayView                (parked/trayed cards strip)
    │
    └── [focusedSessionID != nil] → FullScreenTerminalView
        └── SingleSessionTerminalView  (Supacool's equivalent of WorktreeTerminalTabsView,
                                         but for exactly one tab — no tab bar, no siblings)
            └── TerminalSplitTreeAXContainer (supacode, reused) → GhosttySurfaceView

Sheets mounted on BoardRootView: NewTerminalSheet, LinearInboxSheet, TrashSheet (with
WorktreeJanitorSheet tab), DebugSessionSheetView. The board header also hosts
PRPulseButton (repo-wide PR badge + popover) and BoardVitalsChip (fleet vitals with
per-bucket session counts).
```

The **toolbar** on `BoardRootView` hosts: `RepoPickerButton` (popover with multi-select + Add Repository), `ToolbarSpacer(.flexible)`, `+ New Terminal` button, and a DEBUG-only "Add Fake Session" button. Window title is hidden via `.toolbar(removing: .title)` — the macOS menu bar + window menu still say "Supacool" because that's what `Window("Supacool", ...)` sets.

## The agent spawn path

1. User hits ⌘N or the `+` button in the toolbar.
2. `BoardFeature.openNewTerminalSheet(repositories:)` populates `newTerminalSheet` with a `NewTerminalFeature.State(availableRepositories:)`.
3. User fills in prompt / picks agent / toggles worktree / picks repo → hits Create.
4. `NewTerminalFeature.createButtonTapped` validates, then in a `.run { send in … }` effect:
    - If `useWorktree`: `gitClient.createWorktree(branch, repoRoot, baseDir, false, false, baseRef)` returns a fresh `Worktree`.
    - Else: resolves the repo-root `Worktree` from `repository.worktrees` (or synthesizes one).
    - Dispatches `terminalClient.send(.createTabWithInput(worktree, input: agent.command(prompt:) + "\r", runSetupScriptIfNew: false, id: sessionID))`.
    - Builds `AgentSession(id: sessionID, ...)` and emits `.sessionReady(session)`.
5. `BoardFeature.createSession(session)` appends to `sessions`. **It does NOT set `focusedSessionID`** — the user stays on the board while the agent spawns in the background; the card just appears in In Progress.

Resume and Rerun follow similar shapes (see `resumeDetachedSession`, `rerunDetachedSession` in `BoardFeature`).

## Busy-state wiring

`WorktreeTerminalManager` (supacode) has always consumed agent-hook socket messages. Supacool added two public queries to read that state per session:

```swift
func isAgentBusy(worktreeID: Worktree.ID, tabID: TerminalTabID) -> Bool
func sessionTabExists(worktreeID: Worktree.ID, tabID: TerminalTabID) -> Bool
```

Both forward to the per-worktree `WorktreeTerminalState` (`isTabBusy(_:)` and `containsTabTree(_:)` respectively, which Supacool made non-private).

`BoardRootView.classify(_:)` runs these reads against each session on every re-render. The `@Observable` tracking in supacode's state objects propagates re-renders automatically.

`SessionCardContainer` also observes `isBusyNow` via `.onChange` to dispatch `BoardFeature.updateSessionBusyState(id:busy:)` every time the flag flips — that's what persists `lastKnownBusy` so relaunch classification can tell `.detached` (idle before shutdown) from `.interrupted` (busy at shutdown).

## Card status classifier (in `BoardRootView.classify`)

```
Tab does NOT exist in WorktreeTerminalManager:
  session.lastKnownBusy == true  → .interrupted  (yellow warning triangle, "Interrupted")
  session.lastKnownBusy == false → .detached     (gray moon, "Idle")
Tab exists:
  isAgentBusy == true                          → .inProgress  (green dot, "Working")
  !hasCompletedAtLeastOnce && no hook event yet → .fresh      (blue sparkle, "Starting")
  otherwise                                    → .waitingOnMe (orange exclaim, "Waiting")
```

`.fresh` waits on the session's first hook event so a just-created card doesn't flip to "Waiting" while claude/codex is still initializing. A 30-second fallback prevents broken or missing hooks from leaving a card in "Starting" forever.

## Persistence paths

All persistence lives in `~/.supacool/` via `SupacoolPaths.baseDirectory`:

- `~/.supacool/sessions/<uuid>/session.json` — one directory per `AgentSession`, via `AgentSessionsKey` → `SessionDirectoryStore`. **This replaced the old single `agent-sessions.json` array.** The board list is derived by scanning the directory (priority first, then most-recently-updated); an undecodable session file is skipped, never fatal. Saves are coalesced onto a utility queue and written per-session atomically — only changed session files are rewritten.
- `~/.supacool/agent-sessions-recovery.json` — crash-safety journal via `SessionRecoveryStore`: removed sessions are recorded *before* their folder is deleted, so a buggy or racing shrink can never silently lose data.
- `~/.supacool/board-filters.json` — `BoardFilters` via `BoardFiltersKey`
- `~/.supacool/bookmarks.json` — `[Bookmark]` via `BookmarksKey`
- `~/.supacool/drafts.json` — `[Draft]` via `DraftsKey`
- `~/.supacool/trashed-sessions.json` — `[TrashedSession]` via `TrashedSessionsKey` (3-day recovery window)
- `~/.supacool/linear-inbox.json` — Linear inbox tickets via `LinearInboxKey`
- `~/.supacool/remote-hosts.json` / `remote-workspaces.json` — SSH remote hosts/workspaces via `RemoteHostsKey` / `RemoteWorkspacesKey`
- `~/.supacool/layouts.json` — `[Worktree.ID: TerminalLayoutSnapshot]` (inherited from upstream supacode, unchanged)
- `~/.supacool/settings.json` — app settings (inherited, unchanged)
- `~/.supacool/repos/<name>/…` — per-repo state and worktree checkouts (inherited, unchanged)

All plain JSON; safe to inspect and edit by hand when debugging. Upstream supacode uses `~/.supacode/` — the two are cleanly separate.

**Testing seam**: the sessions directory is injected via the `sessionStorageLocations` dependency. Tests **must** run with the `.dependencies` trait so each test resolves its own temp directory — otherwise concurrent tests share one `@Shared(.agentSessions)` box and pollute each other. See the doc comment on `AgentSessionsKey.swift`.

## The former "orphan" inventory (deleted July 2026)

The sidebar/detail views, the terminal tab-bar UI (`supacode/Features/Terminal/TabBar/`),
`WorktreeTerminalTabsView`, and `SidebarCommands` — 42 files supacode wrote and Supacool
never rendered — were deleted after per-file reachability verification. If an upstream
cherry-pick reintroduces one, it's dead on arrival; drop it rather than wiring it up.

What survives in `supacode/Features/Repositories/Views/` is **live**: the
`PullRequestStatusButton` cluster (used by `SessionCardView` / `FullScreenTerminalView`),
`WorktreeCreationPromptView` (sheet in `ContentView`), and `SidebarSelection` /
`SidebarViewMode` (consumed by the still-live `RepositoriesFeature` reducer). Likewise all
of `supacode/Features/Terminal/Views/` is live — the split-tree renderer
(`TerminalSplitTreeView` + `SplitView` + overlays) is exactly what
`SingleSessionTerminalView` mounts for the full-screen session view.

## Where things talk

- **Agent hook → session state**: `AgentHookSocketServer.onBusy` / `onNotification` closures in `WorktreeTerminalManager.configureSocketServer`. The `onNotification` closure also calls `captureAgentNativeSessionID(tabID:notification:)` which writes `session_id` into the `@Shared(.agentSessions)` store, so Resume can relaunch the exact conversation. Full wire spec (env vars, message formats, install paths, remote forwarding): [`hook-protocol.md`](./hook-protocol.md).
- **Create a session → spawn a PTY**: `NewTerminalFeature` → `TerminalClient.send(.createTabWithInput(...))` → `WorktreeTerminalManager.handleTabCommand` → `WorktreeTerminalState.createTab(initialInput:)` → ghostty.
- **Repository registration**: same flow as upstream supacode — file importer in `ContentView` → `RepositoriesFeature` actions.
