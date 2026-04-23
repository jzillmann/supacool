# Cherry-picking from upstream supacode

Supacool is no longer a live fork — `main` has decoupled from `supabitapp/supacode`. The `upstream` git remote is kept around purely as a **reference for occasional cherry-pick raids** when supacode ships something genuinely useful (terminal/ghostty fixes, low-level keybinding gates, etc.).

This is **not a routine operation**. Every cherry-pick is a deliberate evaluation — most upstream work isn't relevant to Supacool's Matrix Board world.

## Setup

The `upstream` remote should already be configured:

```bash
git remote -v
# upstream  git@github.com:supabitapp/supacode.git (fetch)
# upstream  git@github.com:supabitapp/supacode.git (push)
```

If it isn't:

```bash
git remote add upstream git@github.com:supabitapp/supacode.git
```

## Survey what's available

```bash
git fetch upstream
git log --oneline main..upstream/main | head -50
```

You'll see commits that haven't landed on Supacool's `main`. **Most won't matter.** Skim for:

- Terminal / ghostty fixes (keybindings, `performKeyEquivalent`, split handling)
- Crash fixes
- Bug fixes in code Supacool actually uses
- Specific PRs you've heard about externally

Skip on sight:

- Sidebar / `WorktreeRow` / `SidebarItem` refactors — Supacool deleted the sidebar
- New features built on supacode's CLI/socket transport — Supacool's agent model is the inverse
- Settings UI restructures — Supacool's Settings surface is mostly irrelevant
- Tuist build-graph changes — Supacool stays on `Makefile + xcodebuild`

## Evaluate before picking

For each candidate commit:

```bash
git show --stat <sha>          # see file count and size
git show <sha>                 # see the actual changes
```

Red flags that signal "skip this PR":

- It touches `SidebarItem*`, `SidebarView`, `WorktreeRow*` — Supacool's sidebar is gone.
- It depends on `SupacodeSettingsShared/` — that module split is part of upstream's Tuist migration, which Supacool doesn't have.
- It depends on `CLISkillContent`, `SkillAgent`, `DeveloperSettingsView` — these belong to upstream's CLI/socket transport subsystem (PR #227 onward), which Supacool doesn't share.
- It depends on a chain of preceding upstream PRs Supacool didn't pull.
- The bulk of the diff is plumbing for a feature Supacool models differently.

Green flags:

- Small, surgical fixes to files Supacool still uses verbatim (notably `GhosttySurfaceView.swift`, `WorktreeTerminalManager.swift`, `WorktreeTerminalState.swift`, `GhosttyRuntime.swift`).
- Pure ghostty submodule bumps (handled separately — see below).
- Test additions for behavior Supacool also exhibits.

## Pick

```bash
git cherry-pick <sha>
```

If clean: build + test, amend any fixups, move on.

If conflicts: read each one. Most conflicts in shared files are **independent additions in the same neighborhood** (Supacool added one method, upstream added another). Resolve by keeping both. Conflicts in code Supacool deleted (sidebar plumbing) almost always mean the PR depends on infrastructure Supacool no longer has — abort and skip.

```bash
# After cherry-pick + manual fixes
make build-app
make test    # or scoped test target
git commit --amend --no-edit       # fold any post-pick fixes into the cherry-pick
```

## When in doubt — abort

```bash
git cherry-pick --abort
```

There's no penalty. The decoupling means we don't owe upstream's history any allegiance — every pull is opt-in based on actual value.

## Bumping the ghostty submodule independently

The Ghostty submodule (`ThirdParty/ghostty`) can be bumped independently of supacode entirely — it's a direct dependency of Supacool, not a transitive one through supacode.

```bash
cd ThirdParty/ghostty
git fetch origin
git checkout <new-pin>            # tag, branch, or sha
cd ../..
git add ThirdParty/ghostty
git commit -m "Bump ghostty to <pin>"

# Rebuild and test
make build-ghostty-xcframework
make build-app
make test
```

Watch for: ghostty C-API breaks (rare but possible) — `GhosttyRuntime`, `GhosttySurfaceBridge`, `GhosttySurfaceView` are the Swift sites that talk to the C API directly.

## When NOT to cherry-pick

- If you haven't fetched upstream in a while and there's a 50+ commit pile-up. Browse, don't bulk-merge.
- If the PR touches `RepositoriesFeature`, `AppFeature`, or any other reducer Supacool has materially diverged from. Reapply by hand if the underlying *idea* is valuable; don't try to merge upstream's structure.
- If it depends on infrastructure Supacool has deliberately decided not to adopt (Tuist, CLI/socket transport, the SupacodeSettingsShared module, the sidebar UI).

## Last-resort: replay the idea, not the code

If upstream solves a problem Supacool also has, but in a way that doesn't fit our architecture, **steal the idea, write the code yourself.** The git provenance doesn't matter; the design lesson does. Note the source PR in your commit message for posterity.
