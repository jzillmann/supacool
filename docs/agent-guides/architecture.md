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
├── id: UUID                       — ALSO the TerminalTabID.rawValue
├── repositoryID: String           — Repository.ID (repo root path)
├── worktreeID: String             — Worktree.ID (directory path)
├── agent: AgentType               — .claude | .codex
├── initialPrompt: String          — verbatim, used for Rerun
├── displayName: String            — user-editable, defaults to deriveDisplayName(prompt)
├── createdAt / lastActivityAt     — Date
├── hasCompletedAtLeastOnce: Bool  — flips true on first busy→idle
├── lastKnownBusy: Bool            — persisted busy flag, used to distinguish .detached vs .interrupted on relaunch
└── agentNativeSessionID: String?  — captured from the agent hook payload (claude's session_id); used for Resume
```

**Key invariant**: `AgentSession.id` equals the Ghostty tab ID. This is what lets `WorktreeTerminalManager.isAgentBusy(worktreeID:tabID:)` be looked up per-session without a separate mapping table. Don't break it.

## State hierarchy (TCA)

```
AppFeature.State                    (supacode, modified)
├── repositories: RepositoriesFeature.State  (supacode — registered repos live here)
├── settings:     SettingsFeature.State      (supacode)
├── commandPalette, updates, etc.            (supacode)
└── board:        BoardFeature.State         (Supacool — adds this)
    ├── sessions: [AgentSession]             @Shared(.agentSessions) → JSON on disk
    ├── filters:  BoardFilters               @Shared(.boardFilters)  → JSON on disk
    ├── focusedSessionID: AgentSession.ID?   (transient — UI mode switch)
    └── newTerminalSheet: NewTerminalFeature.State?   @Presents
```

`RepositoriesFeature.State` continues to own the registered-repos list. `BoardFeature` doesn't duplicate it — instead, actions that need the list (`openNewTerminalSheet`, `rerunDetachedSession`, `resumeDetachedSession`) take `[Repository]` as a parameter, passed from the view.

## View hierarchy

```
ContentView                         (supacode/App/, modified)
└── BoardRootView                   (Supacool/Features/Board/Views/)
    ├── [focusedSessionID == nil] → BoardView
    │   └── SessionCardContainer (hover, busy-change observer)
    │       └── SessionCardView  (name, chips, status)
    │
    └── [focusedSessionID != nil] → FullScreenTerminalView
        └── SingleSessionTerminalView  (Supacool's equivalent of WorktreeTerminalTabsView,
                                         but for exactly one tab — no tab bar, no siblings)
            └── TerminalSplitTreeAXContainer (supacode, reused) → GhosttySurfaceView
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
  !hasCompletedAtLeastOnce && age < 3 seconds  → .fresh       (blue sparkle, "Starting")
  otherwise                                    → .waitingOnMe (orange exclaim, "Waiting")
```

`.fresh` is a 3-second grace window so a just-created card doesn't immediately flip to "Waiting" before claude/codex sends its first busy signal.

## Persistence paths

All persistence lives in `~/.supacode/` (shared with stock supacode — see [`persistence.md`](./persistence.md) for why we accept that overlap):

- `~/.supacode/agent-sessions.json` — `[AgentSession]` via `AgentSessionsKey` (Supacool)
- `~/.supacode/board-filters.json` — `BoardFilters` via `BoardFiltersKey` (Supacool)
- `~/.supacode/layouts.json` — `[Worktree.ID: TerminalLayoutSnapshot]` (supacode, unchanged)
- `~/.supacode/settings.json` — app settings (supacode, unchanged)
- `~/.supacode/repos/<name>/…` — per-repo state including repository settings (supacode, unchanged)

All these are plain JSON; safe to inspect and edit by hand when debugging.

## The "orphan" inventory

Files supacode wrote, Supacool doesn't reference, but kept on disk for clean upstream merges:

- `supacode/Features/Repositories/Views/SidebarView.swift`
- `supacode/Features/Repositories/Views/SidebarListView.swift`
- `supacode/Features/Repositories/Views/SidebarViewMode.swift`
- `supacode/Features/Repositories/Views/WorktreeRow.swift`
- `supacode/Features/Repositories/Views/WorktreeRowsView.swift`
- `supacode/Features/Repositories/Views/WorktreeDetailView.swift`
- `supacode/Features/Repositories/Views/WorktreeDetailTitleView.swift`

Don't edit these expecting UI changes. If an upstream merge modifies them, accept the upstream version wholesale.

## Where things talk

- **Agent hook → session state**: `AgentHookSocketServer.onBusy` / `onNotification` closures in `WorktreeTerminalManager.configureSocketServer`. The `onNotification` closure also calls `captureAgentNativeSessionID(tabID:notification:)` which writes `session_id` into the `@Shared(.agentSessions)` store, so Resume can relaunch the exact conversation.
- **Create a session → spawn a PTY**: `NewTerminalFeature` → `TerminalClient.send(.createTabWithInput(...))` → `WorktreeTerminalManager.handleTabCommand` → `WorktreeTerminalState.createTab(initialInput:)` → ghostty.
- **Repository registration**: same flow as upstream supacode — file importer in `ContentView` → `RepositoriesFeature` actions.
