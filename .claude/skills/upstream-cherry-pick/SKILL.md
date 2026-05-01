---
name: Supacool upstream cherry-pick
description: Evaluate and cherry-pick selected commits from upstream supabitapp/supacode. Use when asked to check upstream for useful changes, port a specific upstream fix, or update the ghostty submodule.
---

# Supacool upstream cherry-pick

Goal: opportunistically pull genuinely useful changes from `supabitapp/supacode` into Supacool's `main`. Supacool decoupled from upstream at v0.8.0 — this is **not** a routine sync; every pick is a deliberate evaluation. Deep reference: [`docs/agent-guides/upstream-cherry-pick.md`](../../../docs/agent-guides/upstream-cherry-pick.md).

## Pre-flight: never run in the root checkout

**The root checkout at `/Users/jz/Projects/morethan/supacool` must always stay on `main`.** Cherry-pick / submodule-bump work happens in a worktree, so a feature branch never strands the root off `main`. Run this check before doing anything else:

```bash
if [ "$(git rev-parse --git-dir)" = "$(git rev-parse --git-common-dir)" ]; then
  echo "ABORT: this skill must run from a worktree, not the primary checkout."
  echo "Ask Comandante to launch a new card/session against a worktree, then retry."
  exit 1
fi
```

If the check fires, **stop and report**. Do not commit on the root checkout, do not create a topic branch on the root, do not try to fix it yourself — the recovery is for Comandante to redirect the work into a worktree.

## Survey

```bash
git fetch upstream
git log --oneline main..upstream/main | head -30
```

Triage each candidate aloud for Comandante. Default stance is **skip** — only flag commits with a clear payoff for Supacool. Especially flag:

- Terminal / ghostty fixes touching `GhosttySurfaceView`, `GhosttyRuntime`, `WorktreeTerminalManager`, `WorktreeTerminalState`
- Crash fixes
- Bug fixes in code paths the Matrix Board exercises

Especially **skip**:

- Sidebar refactors (`SidebarItem*`, `WorktreeRow*`) — Supacool deleted the sidebar
- Anything depending on `SupacodeSettingsShared/` (Tuist module split — not in Supacool)
- Anything built on the CLI/socket transport (PR #227 onward — `CLISkillContent`, `SkillAgent`, `DeveloperSettingsView`)
- Tuist build-graph changes — Supacool stays on Makefile + xcodebuild

## Evaluate one PR

```bash
git show --stat <sha>      # size + file count
git show <sha>             # content
```

If the diff is mostly in files Supacool deleted/renamed, or it pulls in an infrastructure subsystem Supacool doesn't have, skip and report that clearly.

## Pick

```bash
git cherry-pick <sha>
```

Conflict patterns:

| Pattern | Resolution |
|---|---|
| Both branches added unrelated methods near each other | Keep both |
| Upstream import we don't have a module for | Drop the import, verify build still passes |
| Upstream renames a Supacool-deleted file | Abort the cherry-pick |
| Upstream depends on a type/file Supacool doesn't have | Abort — pulling the dependency chain is not worth it |

```bash
# Resolve conflicts, then:
git add <files>
git cherry-pick --continue --no-edit

# Verify:
make build-app
make test            # or scoped test class

# If post-pick fixes were needed:
git commit --amend --no-edit
```

## Bumping ghostty independently

Often the most valuable thing in upstream is just the ghostty submodule pin.

```bash
git -C ThirdParty/ghostty fetch origin
git -C ThirdParty/ghostty log -1 --format='%h %s (%ad)' --date=short upstream/main:ThirdParty/ghostty 2>/dev/null \
  || git ls-tree upstream/main ThirdParty/ghostty
# pick a target commit (or upstream/main HEAD of ghostty itself)
git -C ThirdParty/ghostty checkout <pin>
git add ThirdParty/ghostty
git commit -m "Bump ghostty to <pin>"
make build-ghostty-xcframework
make build-app
```

If our pin is already newer than upstream's, say so and skip.

## When something goes wrong

```bash
git cherry-pick --abort
```

No penalty. Report the reason to Comandante (e.g. "PR #X depends on the CLI socket subsystem we never adopted") and move on.

## Sanity check after pulling

1. `make build-app` succeeds.
2. `make test` passes (at minimum BoardFeatureTests, NewTerminalFeatureTests, SplitTreeTests).
3. `make run-app` launches to the Matrix Board.
4. Create a new card, click into full-screen, ⌘E split, ⌘W close — basic terminal flows still work.
5. Quit, relaunch — sessions restore.

Push only after all five pass.

## When NOT to cherry-pick

- Bulk pulls — never. One PR at a time, evaluated individually.
- If Comandante hasn't asked. Silence on upstream is the default.
- If upstream just shipped a big refactor — wait for fixups to land before evaluating.
