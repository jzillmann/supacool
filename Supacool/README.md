# Supacool — personal extensions

This directory is a placeholder for Supacool-specific source code that extends or augments the upstream supacode base.

## Why it's separate from `supacode/`

Supacool is a personal fork of [supabitapp/supacode](https://github.com/supabitapp/supacode). The `main` branch of this repository tracks upstream bit-identically so that `git pull upstream main` is always a clean fast-forward. All personal customizations live on the long-running `supacool` branch.

To keep the merge story painless, the goal is to put Supacool-specific code in *sibling files*, not in-place edits to files under `supacode/`. That way:

- An upstream change to `supacode/Features/Terminal/Foo.swift` doesn't touch any file in `Supacool/`.
- A Supacool change to `Supacool/RemoteSessionCoordinator.swift` doesn't touch any file in `supacode/`.
- `git pull upstream main` followed by `git rebase main` on `supacool` produces zero conflicts in the common case.

Of course some extensions will genuinely need to hook into supacode internals — those become single-line injection points in `supacode/` that call into `Supacool/`. The injection point is the only edit; the logic lives here.

## Current status

Empty. Nothing here yet. First inhabitants (roadmap from `/Users/jz/.claude/plans/binary-jumping-donut.md`):

- **Phase 3a** — first-class SSH sessions. Registered hosts picker, remote-aware session model, visual indicators for local vs. remote terminals.
- **Phase 3b** — clipboard bridge for remote claude sessions. Intercepts ⌘V, uploads images over our own scp channel, injects the remote path into the PTY.
- **Phase 3c** — session management divergence. Optional worktrees, pause/resume sessions.

## How to wire files into the Xcode target

When you add a new `.swift` file under `Supacool/`, you'll need to add it to the `supacode` Xcode target membership before it gets compiled. Easiest via Xcode UI: drag the new file into the project navigator under the `Supacool` group (create it if missing), and check the `supacode` target membership checkbox.

Don't edit `supacode.xcodeproj/project.pbxproj` by hand unless you really know what you're doing — the format is fragile and mis-edits can corrupt the project.
