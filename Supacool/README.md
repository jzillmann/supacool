# Supacool assets directory

This directory holds Supacool's **non-code** artefacts: the app icon source (`assets/app-icon.svg`) and this README. Nothing here is compiled into the Xcode target.

For everything else — the project overview, quickstart, and deep reference docs — see:

- [`/AGENTS.md`](../AGENTS.md) — master doc: fork orientation, quickstart, upstream supacode notes. `CLAUDE.md` symlinks to it.
- [`/docs/agent-guides/`](../docs/agent-guides/) — architecture, persistence convention, Swift 6 gotchas, upstream-sync playbook, and the explicit out-of-scope list.
- [`/.claude/skills/`](../.claude/skills/) — invokable skill modules for recurring workflows.

## Why code lives under `supacode/Supacool/`, not here

Supacool's Xcode project uses `PBXFileSystemSynchronizedRootGroup` (objectVersion 77), which auto-discovers `.swift` files inside the synchronized folders. The only synchronized roots are `supacode/` and `supacodeTests/`. Putting code under `supacode/Supacool/` means it auto-compiles without any project-file surgery.

Adding **top-level** `Supacool/` as a new synchronized root would require hand-editing `supacode.xcodeproj/project.pbxproj` — risky and for no real benefit. So this directory stays for docs/assets only, and `supacode/Supacool/` is where the actual Supacool Swift code lives.
