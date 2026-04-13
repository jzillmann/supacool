---
name: Supacool upstream sync
description: Rebase the Supacool branch onto a fresh pull from upstream supacode. Use when asked to pull upstream changes, sync with supacode main, or resolve rebase conflicts in this fork.
---

# Supacool upstream sync

Goal: pull the latest changes from `supabitapp/supacode` and rebase the `supacool` branch on top. Deep reference: [`docs/agent-guides/upstream-sync.md`](../../../docs/agent-guides/upstream-sync.md).

## Preflight

```bash
git status        # working tree must be clean
git fetch upstream --tags
git log main..upstream/main --oneline | head -20   # preview what's coming
```

If there are uncommitted changes, stop and ask Comandante whether to stash, discard, or commit them first.

## The sync

```bash
git checkout main
git pull upstream main           # fast-forward, main has no personal commits
git push origin main             # keeps your fork's main in sync

git checkout supacool
git rebase main                  # reapply Supacool commits on new upstream HEAD
```

If the rebase completes clean, verify and push:

```bash
make build-app
xcodebuild test ... -only-testing:supacodeTests/BoardFeatureTests -only-testing:supacodeTests/NewTerminalFeatureTests ...
git push --force-with-lease origin supacool
```

## When conflicts happen

Conflicts cluster around the small set of supacode files Supacool legitimately edits. Resolution rules of thumb:

| Conflicting file | Default resolution |
|---|---|
| `supacode/App/ContentView.swift` | Keep Supacool's body (BoardRootView). Cherry-pick upstream modifiers if valuable. |
| `supacode/App/supacodeApp.swift` | Keep `Window("Supacool", ...)`, the `NSApplication.shared.activate(...)` call, dropped `SidebarCommands()`. Re-apply if restructured. |
| `supacode/Features/App/Reducer/AppFeature.swift` | Keep `var board`, `case board`, the no-op switch case, and the `Scope(state: \.board, action: \.board)`. |
| `supacode/Features/Terminal/BusinessLogic/WorktreeTerminalManager.swift` | Keep Supacool's additions (`agentSessions` @Shared, `captureAgentNativeSessionID`, `isAgentBusy`, `sessionTabExists`). |
| `supacode/Features/Terminal/Models/WorktreeTerminalState.swift` | Keep `isTabBusy` non-private, keep `containsTabTree`. |
| `supacode/Features/Repositories/Views/*` (sidebar files) | Accept upstream wholesale. These are orphaned in Supacool. |
| `supacode/Assets.xcassets/AppIcon.appiconset/*.png` | Keep Supacool's matrix icon. |
| `supacode/Info.plist` | Keep Supacool's display name, permission strings, deep-link scheme. |
| `supacode.xcodeproj/project.pbxproj` | Merge carefully. Keep `PRODUCT_NAME = Supacool`, `PRODUCT_BUNDLE_IDENTIFIER = app.morethan.supacool`, `INFOPLIST_KEY_CFBundle*`. Take upstream changes to other settings. |
| `Makefile` | Keep `-Dxcframework-target=native` and `log-stream` subsystem set to `app.morethan.supacool`. |
| `AGENTS.md` / `CLAUDE.md` | Keep Supacool's banner at the top; let upstream changes flow to the rest. |

`docs/agent-guides/upstream-sync.md` has the exhaustive list with rationale.

## When something goes wrong

If the rebase leaves the working tree in a broken state:

```bash
git rebase --abort                       # bail out of the current rebase
git checkout supacool
git reset --hard origin/supacool         # restore to last pushed state
```

Then take a breath, look at what upstream actually changed (`git log upstream/main`), and try a narrower rebase — maybe onto an earlier upstream commit first.

Never force-push without `--force-with-lease`. Never merge `main` into `supacool`.

## After sync — the five-minute sanity check

1. `make build-app` → succeeds.
2. `make test` → at minimum, BoardFeatureTests and NewTerminalFeatureTests pass.
3. `make run-app` → launches to the Matrix Board.
4. Create a new terminal card; it appears in "In Progress".
5. Click it; fullscreen terminal opens; `Esc` returns.

If any of those fail, STOP and investigate before pushing. A broken rebase pushed to origin is painful to undo.

## When NOT to sync

- If upstream has just shipped a risky-looking refactor (big diffs in WorktreeTerminalManager, AppFeature, or the ghostty submodule), wait a few days for upstream to land fixups.
- If you're in the middle of a Supacool feature and your working tree is dirty. Finish and commit the feature first.
- If Comandante hasn't asked for the sync. Upstream velocity is high; syncing on a schedule is fine, syncing reactively on every push is noise.
