# Feature index — what exists and where it lives

One dense page mapping every shipped subsystem to its primary files, so nobody (human or
agent) has to rediscover a feature from source. **Maintenance rule**: when you ship a
feature or materially reshape one, update its row here in the same commit (see
`AGENTS.md` § Documentation system). Names are real file names — `fd <name>` finds them.

| Feature | What it does | Primary files | Deep doc |
|---|---|---|---|
| Matrix Board (core) | Card per agent session; Waiting on Me / In Progress buckets; full-screen terminal on tap; swipe-nav | `BoardFeature.swift` (+ `BoardFeature+SessionLifecycle.swift`, `+References.swift`, `+PRPulse.swift` extension files), `BoardRootView.swift`, `BoardView.swift`, `SessionCardView.swift`, `FullScreenTerminalView.swift`, `Supacool/Domain/AgentSession.swift` | [architecture.md](./architecture.md) |
| Session persistence | Per-session directory store, crash-safe removals, detached/interrupted classification, Rerun + Resume. Resume rebuilds a worktree that trash deleted (`--resume` is cwd-scoped, so the agent must land in the original directory or it can't find the conversation); if the branch is gone too it fails with a `sessionResumeFailed` tray card instead of resuming in the wrong directory | `AgentSessionsKey.swift`, `SessionDirectoryStore.swift`, `SessionRecoveryStore.swift`, `BoardFeature+SessionLifecycle.swift` (`recreateWorktreeIfMissing`) | [persistence.md](./persistence.md) |
| New Terminal sheet | Prompt, agent picker, unified workspace picker (repo root / worktrees / branches / new branch), AI-assisted branch names (wand), drafts, PR-URL and Linear-ticket prefill | `NewTerminalFeature.swift`, `NewTerminalSheet.swift`, `PromptTextEditor.swift`, `Supacool/Clients/BackgroundInferenceClient.swift` | [architecture.md](./architecture.md) § spawn path |
| Agent registry | Claude / Codex / pi as pluggable agent types (commands, hook config, resume flags) | `Supacool/Domain/AgentType.swift`, `AgentRegistry.swift` | — |
| Hook socket / busy state | Agents report busy + notifications over a Unix socket; drives card buckets and Resume | `AgentHookSocketServer.swift`, `AgentHookSettingsCommand.swift`, `ClaudeHookSettings.swift`, `CodexHookSettings.swift` | [hook-protocol.md](./hook-protocol.md) |
| Linear inbox | Paste/collect Linear tickets, refresh metadata, assign to me, start a session on a ticket; ticket auto-fill in the sheet | `LinearInboxFeature.swift`, `LinearInboxSheet.swift`, `Supacool/Clients/LinearClient.swift`, `Supacool/Domain/LinearTicket.swift`, `LinearInboxKey.swift` | — |
| PR Pulse | Repo-wide PR badge + popover: checks, Greptile scores, merge conflicts, whose-court ball state, opt-in auto-resume on mechanical bounces (per-case toggles + editable prompt templates in Settings → Notifications; simultaneous conditions combine into one prompt, submitted via a synthesized Enter keypress) | `BoardFeature+PRPulse.swift` (reducer handlers + fetch machinery), `PRPulseButton.swift`, `Supacool/Domain/PRPulse.swift`, `PRBallState.swift`, `Supacool/Domain/AutoResumeSettings.swift`, `Supacool/Clients/PRMonitorClient.swift`, `SupacoolGithubPRClient.swift` | — |
| Worktree Janitor | Scan a repo's worktrees/branches, prune stale ones; lives as a tab in the trash dialog | `WorktreeJanitorFeature.swift`, `WorktreeJanitorSheet.swift`, `Supacool/Clients/WorktreeInventoryClient.swift`, `SupacoolWorktreePruneClient.swift` | — |
| Fleet vitals / footprint | Per-session CPU/memory chips and a header chip with per-bucket session counts | `Supacool/Domain/BoardVitals.swift`, `BoardVitalsChip.swift`, `FootprintChip.swift`, `Supacool/Clients/ProcessFootprintClient.swift`, `SessionFootprintStore.swift` | — |
| Bookmarks / drafts / trash / tray | Respawnable prompt pills; half-finished prompts; 3-day recovery trash; park cards in a tray | `Supacool/Domain/Bookmark.swift`, `Draft.swift`, `TrashedSession.swift`, `BookmarkPillRow.swift`, `DraftPillRow.swift`, `TrashSheet.swift`, `BoardTrayView.swift` | [out-of-scope.md](./out-of-scope.md) §4 for the boundary |
| Remote SSH sessions | Spawn agents on remote hosts via ssh + tmux, hook events forwarded back over a reverse socket | `Supacool/Domain/RemoteHost.swift`, `RemoteHostsFeature.swift`, `Supacool/Clients/RemoteSpawnClient.swift`, `RemoteHookInstaller.swift`, `SSHConfigClient.swift` | [remote-hosts.md](./remote-hosts.md) |
| Transcript recording | Records per-session terminal transcripts for later reading (debug-session and Auto-Observer substrate) | `Supacool/Features/Transcript/TranscriptRecorder.swift`, `TranscriptReader.swift`, `TranscriptEntry.swift` | — |
| Auto-Observer | Per-session idle watcher: a small LLM reads the transcript and auto-answers obvious prompts so overnight runs don't stall | `Supacool/Clients/AutoObserverClient.swift`, `AutoObserverPopover.swift`, `BackgroundInferenceClient.swift` | — |
| Session switcher | ⌘⌥-arrow ⌘-Tab-style overlay cycling sessions, grouped by Waiting / Working | `SessionSwitcherOverlay.swift` | — |
| Reference chips | Linear ticket ids + GitHub PR URLs parsed from the session transcript, surfaced as clickable card chips | `Supacool/Clients/SessionReferenceScanner.swift`, `Supacool/Domain/SessionReference.swift`, `PRReferenceStatusViews.swift` | — |
| Debug this session | Free-text observation sheet that spawns a debug agent in the supacool repo primed with a source trace | `Supacool/Features/Debug/DebugSessionFeature.swift`, `DebugSessionSheetView.swift` | — |
| Skill autocomplete | `/skill` autocomplete in the prompt editor from the repo's skill catalog | `Supacool/Domain/SkillCatalog.swift`, `SkillAutocompletePopover.swift` | — |
| Getting started | First-run onboarding task carousel on the board | `GettingStartedState.swift`, `Supacool/Domain/GettingStartedTask.swift`, `GettingStartedCarouselView.swift` | — |
| Quick diff | Per-session diff sheet | `QuickDiffSheet.swift` | — |
| Single-instance guard | `flock` on `~/.supacool/.instance.lock` blocks a second non-isolated instance; preview via `scripts/preview-isolated.sh` | `Supacool/Services/SingleInstanceGuard.swift` | `AGENTS.md` § previewing |
| Command palette / Settings / Updates | Inherited supacode features, still live (palette actions, settings panes incl. Linear + Remote Hosts, Sparkle) | `supacode/Features/CommandPalette/`, `supacode/Features/Settings/`, `supacode/Features/Updates/` | — |

Rows with `—` in the deep-doc column are documented only by this index and their code;
if you find yourself explaining one at length in a PR or session, that's the signal to
promote it to its own page under `docs/agent-guides/`.

The human-facing feature list in the root [`README.md`](../../README.md) is the marketing
view of this same table — when you add a row here, check whether the README deserves the
bullet too (and vice versa). `docs-lint` checks both.
