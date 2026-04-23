# Supacool sources and assets

This directory holds Supacool's Swift source code plus non-code artefacts (app icon source, this README).

Layout:

- `Clients/`, `Domain/`, `Features/` — Swift source, auto-compiled into the `supacode` Xcode target via `PBXFileSystemSynchronizedRootGroup` (objectVersion 77).
- `assets/app-icon.svg` — source-of-truth for the app icon. Not compiled; regenerated into `supacode/Assets.xcassets/AppIcon.appiconset/` via `scripts/generate-app-icon.sh` (see `docs/agent-guides/build-and-run.md`).
- `README.md` — this file.

Swift files added here are picked up by Xcode automatically on the next build — no project-file surgery needed.

For the project overview, quickstart, and deep reference docs see:

- [`/AGENTS.md`](../AGENTS.md) — master doc: project orientation, quickstart, code conventions. `CLAUDE.md` symlinks to it.
- [`/docs/agent-guides/`](../docs/agent-guides/) — architecture, persistence convention, Swift 6 gotchas, upstream cherry-pick playbook, and the explicit out-of-scope list.
- [`/.claude/skills/`](../.claude/skills/) — invokable skill modules for recurring workflows.

## Why a separate source root

`Supacool/` is a dedicated `PBXFileSystemSynchronizedRootGroup` alongside `supacode/` so that net-new Supacool features live at the top level of the repo rather than nested inside the originally-supacode tree. Historical note: pre-decoupling (before April 2026) code lived under `supacode/Supacool/` to minimize upstream-merge friction; that constraint is gone.
