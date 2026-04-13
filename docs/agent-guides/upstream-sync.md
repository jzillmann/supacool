# Upstream sync

## Branches and remotes

| Name | Purpose |
|---|---|
| `main` | Mirror of `supabitapp/supacode` (the upstream). **Never commit to main.** |
| `supacool` | All personal work. Rebased onto `main` after each upstream pull. |
| `origin` | `git@github.com:jzillmann/supacool.git` (your fork on GitHub) |
| `upstream` | `git@github.com:supabitapp/supacode.git` (their repo) |

Verify:

```bash
git remote -v
# origin    git@github.com:jzillmann/supacool.git (fetch)
# origin    git@github.com:jzillmann/supacool.git (push)
# upstream  git@github.com:supabitapp/supacode.git (fetch)
# upstream  git@github.com:supabitapp/supacode.git (push)
```

## The rebase dance

```bash
# 1. Bring main up to date with upstream.
git checkout main
git pull upstream main           # fast-forward, since we never commit to main
git push origin main             # update your fork's main

# 2. Rebase supacool onto the new main.
git checkout supacool
git rebase main

# 3. Verify the build still works.
make build-app
make test

# 4. Push the rebased branch (force-with-lease, because rebase rewrote history).
git push --force-with-lease origin supacool
```

`--force-with-lease` is the safe version of `--force`: it refuses to push if someone else pushed to `origin/supacool` in the meantime. Use it always.

## What to expect during rebase

Most upstream commits don't touch Supacool code — Supacool lives under `supacode/Supacool/` which supacode doesn't know about. Conflicts usually come from the **four files we do edit in the upstream area**:

1. `supacode/App/ContentView.swift` — Supacool rewrote the root body. Conflicts here are common when upstream touches the sidebar layout. Accept Supacool's version wholesale 95% of the time; merge hand-picked improvements (new scene modifiers, etc.).

2. `supacode/App/supacodeApp.swift` — Supacool dropped `SidebarCommands()`, added `NSApplication.shared.activate(...)` in `applicationDidFinishLaunching`, and changed the window title to `Supacool`. If upstream restructures the `commands { }` block or `@main` struct, re-apply these surgically.

3. `supacode/Features/App/Reducer/AppFeature.swift` — Supacool added `var board: BoardFeature.State` to `State`, a `case board(BoardFeature.Action)` to `Action`, a no-op `case .board:` in the core switch, and a `Scope(state: \.board, action: \.board) { BoardFeature() }`. Always reapply if upstream reshapes `AppFeature`.

4. `supacode/Features/Terminal/BusinessLogic/WorktreeTerminalManager.swift` — Supacool added:
    - `@ObservationIgnored @Shared(.agentSessions)` property
    - `captureAgentNativeSessionID(tabID:notification:)` method
    - `isAgentBusy(worktreeID:tabID:)` and `sessionTabExists(worktreeID:tabID:)` public queries
    - a call into `captureAgentNativeSessionID` from the existing `server.onNotification` closure
   
   All additive. Keep Supacool's additions, take upstream's changes to the rest.

5. `supacode/Features/Terminal/Models/WorktreeTerminalState.swift` — Supacool made `isTabBusy(_:)` non-private and added `containsTabTree(_:)`. Additive.

6. `supacode/Features/Repositories/Reducer/RepositoriesFeature.swift` and related sidebar files (`WorktreeRow.swift`, `WorktreeRowsView.swift`, `SidebarView.swift`, etc.) — these are orphaned but still get edited in upstream merges. **Just accept upstream's version.** Supacool's old changes to them (from Phase 3c pre-matrix-board) are cosmetic and don't affect behavior.

7. `supacode/Assets.xcassets/AppIcon.appiconset/*.png` — the Supacool matrix icon. Always keep Supacool's PNGs.

8. `supacode/Info.plist` — display name, permission strings, bundle identifier-derived keys.

9. `supacode.xcodeproj/project.pbxproj` — bundle id, product name (literal `Supacool`), INFOPLIST_KEY additions. Never accept upstream-wholesale; merge field-by-field.

10. `Makefile` — the `-Dxcframework-target=native` flag in `build-ghostty-xcframework`, and the `log-stream` subsystem set to `app.morethan.supacool`.

## When upstream breaks Supacool

Supacode is actively developed. If an upstream commit refactors `WorktreeTerminalManager` or `AppFeature` in ways that Supacool can't straightforwardly reapply, these are the options from least to most drastic:

1. **Cherry-pick only safe upstream commits.** `git log main..supacool` shows Supacool's commits. `git log upstream/main` shows upstream's. You can rebase `supacool` onto a specific older upstream commit if a particular change is unfriendly.
2. **Pin main at a specific upstream tag.** If upstream ships a breaking change you don't want yet, keep your `main` at an earlier commit and skip the breaking one until Supacool is ready.
3. **Back out the problematic Supacool change temporarily.** If Supacool's extension hooks depend on an upstream API that changed, revert Supacool's edit, then re-apply against the new shape.

## Don't accidentally merge

Never merge `main` into `supacool` (or vice versa). Always rebase. Merges create non-linear history that makes future rebases painful.

If someone (human or AI) accidentally merges:

```bash
git checkout supacool
git reset --hard origin/supacool         # back to the last known-good remote state
# or
git reflog                               # find the pre-merge commit, reset there
```

Use `--force-with-lease` when pushing the corrected branch.

## The sanity checklist after a sync

1. `make build-app` succeeds.
2. `make test` passes at least the Supacool tests (`BoardFeatureTests`, `NewTerminalFeatureTests`).
3. `make run-app` launches. You see the Matrix Board (not a sidebar).
4. Create a new terminal. Card appears. Click it. Full-screen terminal opens.
5. Quit. Relaunch. Sessions come back. Detached cards show Rerun/Resume.

If any of those five fail, something regressed during the rebase — don't push.
