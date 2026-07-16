# Supacool

Personal macOS terminal. **Originally derived from [`supabitapp/supacode`](https://github.com/supabitapp/supacode)** at v0.8.0; since then it has evolved as an independently maintained codebase. License is FSL-1.1-ALv2 (inherited).

This is the master document for anyone (human or AI agent) working in this repo. `CLAUDE.md` is a symlink to this file, so Claude Code and other tooling read it by default.

---

## Read this first: the three things that bite

1. **The UI is not supacode's.** Supacool replaced the `NavigationSplitView(sidebar:, detail:)` layout with the **Matrix Board** — a grid of cards, each one a persistent agent session (claude-code or codex). The orphaned sidebar/detail and tab-bar view files were deleted from the tree in July 2026; if an upstream cherry-pick brings one back, it's dead on arrival — don't wire it up.

2. **Persisted Codable types have a non-obvious invariant.** Every `@Shared` struct needs a manual `init(from decoder:)` using `decodeIfPresent ?? default`. Synthesized Codable silently wipes user data on schema changes. Hard-won lesson. See [`docs/agent-guides/persistence.md`](./docs/agent-guides/persistence.md).

3. **Swift 6 global `@MainActor` isolation is on.** Plain `enum` types used in `Picker(selection:)` must be declared `nonisolated enum` or the `Equatable` conformance is actor-isolated and doesn't satisfy `Sendable`. `@Dependency(\.keyPath)` key-path form breaks Sendable in `.run` blocks — use `@Dependency(Type.self)` instead. Details in [`docs/agent-guides/swift6-gotchas.md`](./docs/agent-guides/swift6-gotchas.md).

---

## Quickstart

```bash
# One-time
brew install mise
mise trust && mise install           # zig, swiftlint, xcsift, create-dmg

# Every build
make build-ghostty-xcframework       # Zig compiles ghostty → Frameworks/GhosttyKit.xcframework
make build-app                       # Xcode build
make run-app                         # Build + launch with log stream
make test                            # Run full test suite

# Only the Supacool tests (faster iteration)
# Keep -derivedDataPath AND PRODUCT_BUNDLE_IDENTIFIER: together they stop the test
# host colliding with your installed/running Supacool. Drop either one and the run
# dies with "Could not launch supacoolTests … LaunchServices launcher returned an
# error" — which reads like a signing problem and is not. Same pair `make test` uses.
xcodebuild test -project supacool.xcodeproj -scheme supacool \
  -destination "platform=macOS" -derivedDataPath build/dd-tests \
  PRODUCT_BUNDLE_IDENTIFIER=io.morethan.supacool.tests \
  -only-testing:supacoolTests/BoardFeatureTests \
  -only-testing:supacoolTests/NewTerminalFeatureTests \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  -skipMacroValidation
```

If `build-ghostty-xcframework` fails with `cannot execute tool 'metal' due to missing Metal Toolchain`: the Makefile already passes `-Dxcframework-target=native` to keep the ghostty build macOS-only. If you still hit it, the fallback is `xcodebuild -downloadComponent MetalToolchain` (~1GB one-time). See [`docs/agent-guides/build-and-run.md`](./docs/agent-guides/build-and-run.md).

### Previewing a branch as a second instance

To eyeball a branch's UI/behaviour next to your real Supacool **without disturbing its data**, use the helper in `scripts/`:

```bash
scripts/build-and-preview.sh [optional/repo/to/seed/on/the/board]
```

It builds the current branch into an isolated DerivedData (`build/`, gitignored), then launches a **detached preview instance**. `scripts/preview-isolated.sh` does the launch alone if you've already built.

Isolation matters because the app stores state in two non-obvious places, neither of which a normal launch separates:
- **File data** (`settings.json`, sessions, bookmarks) lives at a fixed `~/.supacool/` path, *not* under a bundle-id container. The scripts redirect `$HOME` to `~/.supacool-preview-sandbox` to isolate it (delete that dir to reset the preview).
- **UserDefaults** (repo list/order, sidebar state, the `bypassPermissions` flag, …) is keyed by **bundle id** via `cfprefsd`, which ignores `$HOME`. So the scripts re-stamp the built app's bundle id to `io.morethan.supacool.preview` (and ad-hoc re-sign) to get a separate prefs domain.

Without **both** moves, a second instance silently shares — and can corrupt — your real app's repo ordering, settings, and board state. The scripts also strip inherited `SUPACOOL_*` env vars so a preview launched from inside a Supacool terminal can't cross-talk with the parent app's hook socket.

---

## Repo layout

```
.
├── AGENTS.md                 # THIS FILE — master doc
├── CLAUDE.md → AGENTS.md     # symlink (Claude Code convention)
├── Supacool/                 # net-new Supacool Swift source (Board, AgentSession, RemoteHost, etc.)
│   ├── App/                  # app entry point (SupacoolApp, ContentView) — moved from supacode/App
│   ├── Clients/, Domain/, Features/   # auto-compiled into the `supacool` target
│   ├── assets/               # app-icon.svg (non-code)
│   └── README.md
├── supacode/                 # originally-supacode source (top-level dir name kept for historical reasons)
├── supacodeTests/            # tests, grouped by feature area (App/, Board/, Git/, …). Directory name kept; Xcode target is `supacoolTests`.
├── supacool.xcodeproj/       # Xcode project (objectVersion 77, synchronized root groups; targets `supacool` + `supacoolTests`)
├── docs/agent-guides/        # deep reference docs (start here when doing architecture work)
├── .claude/skills/           # Claude-invokable skill modules (recurring workflows)
├── ThirdParty/ghostty/       # Ghostty submodule → GhosttyKit.xcframework
└── Makefile                  # build-ghostty-xcframework, build-app, run-app, test, etc.
```

`Supacool/` and `supacode/` are both `PBXFileSystemSynchronizedRootGroup`s in the same `supacool` Xcode target — Swift files dropped into either directory auto-compile with no project-file surgery. The split is a **convention**: net-new Supacool features go under `Supacool/`, originally-supacode source stays under `supacode/`. In-place edits to anything under `supacode/` are fine — there's no upstream-merge cost to worry about anymore. (The directory names `supacode/` and `supacodeTests/` are kept as historical markers; the Xcode targets they belong to are `supacool` and `supacoolTests`.)

---

## Branches and remotes

- **`main`** — the active branch. All work happens here (or on feature branches PR'd into it).
- **`upstream`** remote — `supabitapp/supacode`. Kept as a read-only reference for occasional cherry-pick raids when upstream ships something interesting (terminal/ghostty fixes, etc.). We do **not** track upstream live; pulls are deliberate, not routine. See [`docs/agent-guides/upstream-cherry-pick.md`](./docs/agent-guides/upstream-cherry-pick.md).
- **`origin`** remote — `jzillmann/supacool`.
- **`archive/upstream-mirror-v0.8.0`** tag — last commit where `main` mirrored upstream verbatim, kept for historical reference.

---

## What's in and what's explicitly out

**In, shipped** — the full feature → files map lives in [`docs/agent-guides/features.md`](./docs/agent-guides/features.md). Headlines:
- Matrix Board primary UI — card per agent session, Waiting on Me / In Progress buckets, repo filter, full-screen terminal on tap, tray, bookmarks/drafts, 3-day trash.
- Session persistence across relaunches (per-session directory store); detached vs interrupted state; Rerun (fresh) and Resume (with captured agent session id).
- New Terminal sheet: prompt, agent (Claude/Codex/pi via the agent registry), repo picker, optional worktree, PR-URL and Linear-ticket prefill.
- Linear inbox, PR Pulse (checks/Greptile/ball-court), Worktree Janitor, fleet vitals, transcript recording, remote SSH sessions (ssh + tmux + forwarded hook socket).
- Forward-compatible Codable on all persisted types; single-instance guard; Metal-free ghostty build.

**Out of scope** (deliberately — see [`docs/agent-guides/out-of-scope.md`](./docs/agent-guides/out-of-scope.md)):
- Workflow engine / autonomous orchestration. The earlier forgn+forgin merger idea is parked. (Read-only Linear/GitHub *surfacing* is in; autonomous *routing* is out.)
- PTY survival across relaunches (tmux-style) for local sessions. Detached/Resume is the substitute.
- Separate "Ready" vs "Wants Input" buckets. Needs a hook-protocol extension we haven't built.
- Stock supacode's sidebar/detail UI. The orphaned files were deleted in July 2026; the live remnants of `Repositories/Views/` are the PR-status cluster and `WorktreeCreationPromptView`.

---

## Deep references

| You want to… | Read |
|---|---|
| Find which files implement a shipped feature | [`docs/agent-guides/features.md`](./docs/agent-guides/features.md) |
| Understand the data model and reducer flow | [`docs/agent-guides/architecture.md`](./docs/agent-guides/architecture.md) |
| Add a new field to a persisted Codable | [`docs/agent-guides/persistence.md`](./docs/agent-guides/persistence.md) |
| Touch busy state, notifications, or hook install | [`docs/agent-guides/hook-protocol.md`](./docs/agent-guides/hook-protocol.md) |
| Understand a Swift 6 compiler error | [`docs/agent-guides/swift6-gotchas.md`](./docs/agent-guides/swift6-gotchas.md) |
| Build / run / test quirks | [`docs/agent-guides/build-and-run.md`](./docs/agent-guides/build-and-run.md) |
| Touch the toolbar, cursor, or text input | [`docs/agent-guides/ui-patterns.md`](./docs/agent-guides/ui-patterns.md) |
| Cherry-pick from upstream supacode | [`docs/agent-guides/upstream-cherry-pick.md`](./docs/agent-guides/upstream-cherry-pick.md) |
| Know what NOT to build | [`docs/agent-guides/out-of-scope.md`](./docs/agent-guides/out-of-scope.md) |
| Change `RemoteHost` / ssh_config handling | [`docs/agent-guides/remote-hosts.md`](./docs/agent-guides/remote-hosts.md) |
| Cut a release (sign, notarize, Sparkle, DMG) | [`RELEASING.md`](./RELEASING.md) |
| Add a new feature end-to-end | Skill: [`.claude/skills/add-feature/SKILL.md`](./.claude/skills/add-feature/SKILL.md) |
| Check the docs for drift against the code | Skill: [`.claude/skills/docs-lint/SKILL.md`](./.claude/skills/docs-lint/SKILL.md) |

### Documentation system

The docs follow a wiki-style discipline (adapted from Karpathy's "LLM Wiki" pattern —
synthesis happens once and stays current, instead of being re-derived from source every
session). Roles:

- **Schema + index**: this file. Conventions live here; the two tables above are the
  index. Content beyond a paragraph goes in a guide page, never inline here.
- **Pages**: `docs/agent-guides/*.md` — one page per subsystem/concern. Pages must
  *synthesize* (invariants, wire contracts, why-decisions) — never mirror what a grep of
  the code answers just as fast. `features.md` is the flat map for everything that
  doesn't warrant a page yet.
- **Human-facing edges**: the root `README.md` (feature storefront — the marketing view
  of `features.md`) and `RELEASING.md` (release runbook). They live outside
  `agent-guides/` but inside the system: indexed above, covered by lint.
- **Log**: git history. We do not keep a separate changelog for docs.
- **Ingest** (on every shipped change): update the `features.md` row and any guide page
  your change made stale, in the same commit. Adding a feature without its index row is
  an incomplete change.
- **Lint** (periodic): run the `docs-lint` skill — it diffs doc claims against the code
  and reports stale paths, dead names, and shipped-but-undocumented subsystems. Run it
  when docs feel off, after big refactors, or roughly monthly.

---

## Code & build conventions

These are the working rules inherited from supacode and still in force.

### Architecture

```
AppFeature (root TCA store)
├─ RepositoriesFeature (repos, worktrees, PR state, archive/delete flows)
├─ CommandPaletteFeature
├─ SettingsFeature (general, notifications, coding agents, shortcuts, github, worktree, repo settings)
├─ BoardFeature (Matrix Board — Supacool's primary UI)
└─ UpdatesFeature (Sparkle auto-updates)

WorktreeTerminalManager (global @Observable terminal state, outside TCA)
└─ WorktreeTerminalState (per worktree)
    └─ TerminalTabManager (tab/split management)
        └─ GhosttySurfaceState[] (one per terminal surface)

GhosttyRuntime (shared runtime)
└─ ghostty_app_t (single C instance)
    └─ ghostty_surface_t[] (independent terminal sessions)
```

The terminal layer (`WorktreeTerminalManager`) is `@Observable` but outside TCA. Communication uses `TerminalClient`: reducers send `Command`s in, receive `Event`s back via `AsyncStream`. Wired in `SupacoolApp.swift`, subscribed in `AppFeature.appLaunched`.

### Code guidelines

- Target macOS 26.0+, Swift 6.0
- Use `@ObservableState` for TCA feature state; use `@Observable` for non-TCA shared stores; never `ObservableObject`
- Always mark `@Observable` classes with `@MainActor`
- Modern SwiftUI only: `foregroundStyle()`, `NavigationStack`, `Button` over `onTapGesture()`
- When reducer logic changes, always add tests
- In unit tests, never use `Task.sleep`; use `TestClock` (or an injected clock) and drive time with `advance`.
- Prefer Swift-native APIs over Foundation where they exist (e.g., `replacing()` not `replacingOccurrences()`)
- Avoid `GeometryReader` when `containerRelativeFrame()` or `visualEffect()` would work
- Do not use NSNotification to communicate between reducers
- Prefer `@Shared` directly in reducers for app storage and shared settings; do not introduce new dependency clients solely to wrap `@Shared`
- Use `SupaLogger` for all logging. Never use `print()` or `os.Logger` directly. `SupaLogger` prints in DEBUG and uses `os.Logger` in release.
- Before doing a big feature or when planning, consult with pfw (pointfree) skills on TCA, Observable best practices first.

### Ghostty keybindings

- Handled via runtime action callbacks in `GhosttySurfaceBridge`, not by app menu shortcuts.
- App-level tab actions should be triggered by Ghostty actions (`GHOSTTY_ACTION_NEW_TAB` / `GHOSTTY_ACTION_CLOSE_TAB`) to honor user custom bindings.
- `GhosttySurfaceView.performKeyEquivalent` routes bound keys to Ghostty first; only unbound keys fall through to the app, and only when the surface is the actual first responder.

### Formatting & linting

- 2-space indentation, 120 character line length (enforced by `.swift-format.json`)
- Trailing commas are mandatory (enforced by `.swiftlint.yml`)
- SwiftLint runs in strict mode over `supacode`, `Supacool`, and `supacodeTests` (Supacool/ joined the lint scope 2026-07-08); never disable lint rules without permission
- Custom SwiftLint rule: `store_state_mutation_in_views` — do not mutate `store.*` directly in view files; send actions instead

### UX standards

- Buttons must have tooltips explaining the action and associated hotkey
- Use Dynamic Type, avoid hardcoded font sizes
- Components should be layout-agnostic (parents control layout, children control appearance)
- Never use custom colors, always use system-provided ones
- Use `.monospaced()` modifier on fonts when appropriate

### Workflow rules

- After a task, ensure the app builds: `make build-app`
- **Docs ingest**: if you shipped or reshaped a feature, update its row in
  [`docs/agent-guides/features.md`](./docs/agent-guides/features.md) and any guide page
  your change made stale — in the same commit. See § Documentation system above.
- Commit your changes only — do not use `git add .`
- **Don't create branches on your own.** We mostly work directly on `main` here. Either you're already on a branch (use it), or we agree on branching first. Don't branch just because you're about to commit — committing straight to `main` is the default.
- Before starting work, check the current branch name; if it's something generic like an animal name, rename it appropriately. Do not do this for `main`.
- After implementing an execplan, submit a PR if you're not on `main`.

### Submodules

- `ThirdParty/ghostty` (`https://github.com/ghostty-org/ghostty`): source dependency used to build `Frameworks/GhosttyKit.xcframework` and terminal resources.
- `Resources/git-wt` (`https://github.com/khoi/git-wt.git`): bundled `wt` CLI used by Git worktree flows at runtime.

---

## License

FSL-1.1-ALv2 (inherited from supacode). Personal / internal use fine; auto-converts to Apache-2.0 in 2028.
