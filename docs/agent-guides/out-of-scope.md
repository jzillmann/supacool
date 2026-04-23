# Out of scope — things Supacool deliberately does NOT do

Supacool started as a broader vision (workflow engine + cockpit + agent orchestration) and shrank to a focused personal terminal. Future sessions will re-discover the shelved ideas and ask whether to build them. **Default answer: no, and here's why.** If you're going to re-open any of these, get explicit scope approval first.

## 1. Workflow engine / agent orchestration

**What it is**: a headless Go service that polls Linear/GitHub, routes issues through `plan → implement → review → iterate` phases, spawns claude in worktrees autonomously. Earlier session designs called this "Lattice Engine". A merger of the `/Users/jz/Projects/web/forgin` (Go) and `/Users/jz/Projects/morethan/forgn` (TS) experiments.

**Why it's out**: Comandante explicitly said "let's go ahead with the fork. and let's get it functional quickly. This will be just my personal CLI terminal." Supacool's scope is the terminal UI. If the workflow-engine vision comes back, it lives in a **separate project** that communicates with Supacool over HTTP/SSE, not as code inside this repo.

**Signals this is creeping back into scope**: anyone talks about adding a scheduled-task / cron / polling loop inside Supacool, or wiring Linear/GitHub webhooks.

## 2. Supervisor-via-CLI (Pi replacement)

**What it is**: on every N agent events, spawn a separate `claude --print` call with a supervisor prompt asking "is this on track, should we interrupt, what's the next instruction?". Gives Pi-style oversight without paying the Anthropic-API tax.

**Why it's out**: lives in the workflow-engine bucket above. If Supacool ever grows an "auto-interrupt" button, that's a shallower version; but a true supervisor loop is engine territory.

## 3. PTY survival across app relaunches (tmux-style)

**What it is**: detach running PTYs from the app before quitting so claude processes keep running, reattach on next launch. Sessions come back mid-conversation.

**Why it's out**: invasive — requires either embedding tmux/zellij or writing our own PTY daemon. The `.detached` + Resume (claude --resume <id>) pattern is the pragmatic substitute: the agent's data survives (via `agentNativeSessionID`), the PTY doesn't. One click and you're back in the same conversation.

**Signals this is creeping back**: anyone adds a background daemon, or anyone talks about a "supacool-daemon" companion process.

## 4. Archive, pin, or group cards

**What it is**: the old sidebar-era flow had "Pinned" / "All" worktree view modes, archive, and manual ordering. The Matrix Board has none of that.

**Why it's out for now**: the repo multi-select filter does most of the triage work. If a session's truly stale, the context-menu Remove handles it. Archiving implies a "not visible but not deleted" tier which needs its own sort/filter UI.

**If the card list gets huge** (>50 sessions), revisit — at that scale, dismissibility matters.

## 5. Rich per-card previews (last assistant snippet, token usage, cost)

**What it is**: cards that show the agent's latest output on the card face, plus metadata like token count or estimated cost.

**Why it's out**: requires wiring into the hook protocol or scraping PTY output. Worth doing when the board gets dense enough that "name + timestamp" isn't enough to triage.

## 6. Mobile / web UI

**What it is**: earlier brainstorms explored a web dashboard served by a headless engine, viewable from phone.

**Why it's out**: Supacool is a native macOS terminal app by design. The "view from anywhere" dream is workflow-engine scope (see #1).

## 7. Renaming everything `supacode` → `Supacool` in source

**What it is**: Xcode target, source directory, module name, all the orphaned view files.

**Why it's out**: a holdover from the fork era — kept because mass renaming is cosmetic, disruptive (Xcode project regeneration, asset paths, log subsystem), and doesn't change behaviour. Rename only the user-visible bits (display name, bundle id, window title). Internal names stay `supacode`.

## 8. Custom fork of ghostty or git-wt

**What it is**: editing the ghostty zig source directly rather than just passing build flags.

**Why it's out**: `ThirdParty/ghostty` and `Resources/git-wt` are submodules. Editing them puts us off their upstream tree, which is a maintenance burden for zero current benefit. Supacool's one `build.zig`-adjacent change (`-Dxcframework-target=native`) is a Makefile flag, not a source edit.

---

## How to handle "should we add X?"

1. Is X on this list? If yes, default "no" unless Comandante explicitly says otherwise.
2. Is X a customization of supacool's existing card/board/terminal UX? Probably yes, go ahead.
3. Is X new infrastructure (services, processes, network protocols)? Probably no — separate project.
4. Is X better solved by cherry-picking from upstream supacode? Review [upstream-cherry-pick.md](./upstream-cherry-pick.md) — but default to "no", since most upstream code carries dependencies we don't share.
