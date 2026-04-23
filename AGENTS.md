# Supacool

Personal macOS terminal, forked from [`supabitapp/supacode`](https://github.com/supabitapp/supacode).

This is the master document for anyone (human or AI agent) working in this repo. `CLAUDE.md` is a symlink to this file, so Claude Code and other tooling read it by default.

---

## Read this first: the four things that bite

1. **This is a fork.** `main` mirrors upstream supacode bit-identically; personal work lives on the `supacool` branch. Editing upstream-owned files casually creates merge pain on every future `git pull upstream main`. Rule of thumb: **new code goes under `supacode/Supacool/`** (an additive subtree of supacode's synchronized folder). In-place edits to existing `supacode/…` source should be small, surgical injection points, not rewrites.

2. **The UI is not supacode's.** Supacool replaced the `NavigationSplitView(sidebar:, detail:)` layout with the **Matrix Board** — a grid of cards, each one a persistent agent session (claude-code or codex). The old sidebar/detail files still exist on disk but are orphaned (not wired to any Scene). Don't touch them expecting UI changes to take effect.

3. **Persisted Codable types have a non-obvious invariant.** Every `@Shared` struct needs a manual `init(from decoder:)` using `decodeIfPresent ?? default`. Synthesized Codable silently wipes user data on schema changes. Hard-won lesson. See [`docs/agent-guides/persistence.md`](./docs/agent-guides/persistence.md).

4. **Swift 6 global `@MainActor` isolation is on.** Plain `enum` types used in `Picker(selection:)` must be declared `nonisolated enum` or the `Equatable` conformance is actor-isolated and doesn't satisfy `Sendable`. `@Dependency(\.keyPath)` key-path form breaks Sendable in `.run` blocks — use `@Dependency(Type.self)` instead. Details in [`docs/agent-guides/swift6-gotchas.md`](./docs/agent-guides/swift6-gotchas.md).

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
xcodebuild test -project supacode.xcodeproj -scheme supacode \
  -destination "platform=macOS" \
  -only-testing:supacodeTests/BoardFeatureTests \
  -only-testing:supacodeTests/NewTerminalFeatureTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  -skipMacroValidation
```

If `build-ghostty-xcframework` fails with `cannot execute tool 'metal' due to missing Metal Toolchain`: the Makefile already passes `-Dxcframework-target=native` to keep the ghostty build macOS-only. If you still hit it, the fallback is `xcodebuild -downloadComponent MetalToolchain` (~1GB one-time). See [`docs/agent-guides/build-and-run.md`](./docs/agent-guides/build-and-run.md).

---

## Repo layout

```
.
├── AGENTS.md                 # THIS FILE — master doc (Supacool + upstream supacode notes)
├── CLAUDE.md → AGENTS.md     # symlink (Claude Code convention)
├── supacode/                 # upstream sources, auto-compiled (synchronized folder)
│   └── Supacool/             # fork code lives here (auto-compiled as subtree)
│       ├── Domain/           # AgentSession, AgentType
│       └── Features/Board/   # the Matrix Board feature (reducer + views + persistence)
├── supacodeTests/            # tests, flat. BoardFeatureTests, NewTerminalFeatureTests, etc.
├── supacode.xcodeproj/       # Xcode project (objectVersion 77, synchronized root groups)
├── Supacool/                 # NON-code: assets (app-icon.svg) + README; NOT in Xcode target
├── docs/agent-guides/        # deep reference docs (start here when doing architecture work)
├── .claude/skills/           # Claude-invokable skill modules (recurring workflows)
├── ThirdParty/ghostty/       # Ghostty submodule → GhosttyKit.xcframework
└── Makefile                  # build-ghostty-xcframework, build-app, run-app, test, etc.
```

---

## Branch strategy

- **`main`** — read-only mirror of upstream `supabitapp/supacode`. Receives `git pull upstream main` fast-forwards. **Never commit to main.**
- **`supacool`** — all personal work. Periodically `git rebase main` after an upstream pull.
- **Remotes**: `upstream` → `supabitapp/supacode` (SSH), `origin` → `jzillmann/supacool`.

```bash
# The sync dance (see docs/agent-guides/upstream-sync.md for the full playbook)
git checkout main && git pull upstream main && git push origin main
git checkout supacool && git rebase main
```

---

## What's in (recent) and what's explicitly out

**In, shipped** (as of the last commits on `supacool`):
- Matrix Board primary UI — card per agent session, Waiting on Me / In Progress buckets, repo filter, full-screen terminal on tap.
- Session persistence across relaunches; detached vs interrupted state; Rerun (fresh) and Resume (with captured agent session id) affordances.
- New Terminal sheet: prompt, agent (Claude/Codex), repo picker, optional worktree creation.
- Forward-compatible Codable on all persisted types.
- App icon, bundle identity (`app.morethan.supacool`, display name "Supacool"), Metal-free ghostty build.

**Out of scope** (deliberately — see [`docs/agent-guides/out-of-scope.md`](./docs/agent-guides/out-of-scope.md)):
- Workflow engine / autonomous orchestration. The earlier forgn+forgin merger idea is parked.
- PTY survival across relaunches (tmux-style). Detached/Resume is the substitute.
- Separate "Ready" vs "Wants Input" buckets. Needs a hook-protocol extension we haven't built.
- Stock supacode's sidebar/detail UI. Files exist but aren't wired; don't edit them.

---

## Deep references

| You want to… | Read |
|---|---|
| Understand the data model and reducer flow | [`docs/agent-guides/architecture.md`](./docs/agent-guides/architecture.md) |
| Add a new field to a persisted Codable | [`docs/agent-guides/persistence.md`](./docs/agent-guides/persistence.md) |
| Understand a Swift 6 compiler error | [`docs/agent-guides/swift6-gotchas.md`](./docs/agent-guides/swift6-gotchas.md) |
| Build / run / test quirks | [`docs/agent-guides/build-and-run.md`](./docs/agent-guides/build-and-run.md) |
| Touch the toolbar, cursor, or text input | [`docs/agent-guides/ui-patterns.md`](./docs/agent-guides/ui-patterns.md) |
| Pull upstream changes in | [`docs/agent-guides/upstream-sync.md`](./docs/agent-guides/upstream-sync.md) |
| Know what NOT to build | [`docs/agent-guides/out-of-scope.md`](./docs/agent-guides/out-of-scope.md) |
| Change `RemoteHost` / ssh_config handling | [`docs/agent-guides/remote-hosts.md`](./docs/agent-guides/remote-hosts.md) |
| Add a new feature end-to-end | Skill: [`.claude/skills/add-feature/SKILL.md`](./.claude/skills/add-feature/SKILL.md) |
| Sync fork with upstream | Skill: [`.claude/skills/upstream-sync/SKILL.md`](./.claude/skills/upstream-sync/SKILL.md) |

---

## License

FSL-1.1-ALv2 (inherited from supacode). Personal / internal use fine; auto-converts to Apache-2.0 in 2028.

---

# Upstream supacode notes

Everything below this line is inherited from upstream supacode. Some of it is stale under Supacool (e.g. the sidebar-based architecture diagram), but we preserve it verbatim to keep `git pull upstream main` clean. Supacool-accurate information is in the Supacool-specific docs linked above; treat this section as "what upstream currently thinks this app is."

## Build Commands

```bash
make build-ghostty-xcframework  # Rebuild GhosttyKit from Zig source (requires mise)
make build-app                   # Build macOS app (Debug) via xcodebuild
make run-app                     # Build and launch Debug app
make install-dev-build           # Build and copy to /Applications
make format                      # Run swift-format only
make lint                        # Run swiftlint only (fix + lint)
make check                       # Run both format and lint
make test                        # Run all tests
make log-stream                  # Stream app logs (subsystem: app.supabit.supacode)
make bump-version                # Bump patch version and create git tag
make bump-and-release            # Bump version and push to trigger release
```

Run a single test class or method:
```bash
xcodebuild test -project supacode.xcodeproj -scheme supacode -destination "platform=macOS" \
  -only-testing:supacodeTests/TerminalTabManagerTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation
```

Requires [mise](https://mise.jdx.dev/) for zig, swiftlint, and xcsift tooling.

## Architecture

Supacode is a macOS orchestrator for running multiple coding agents in parallel, using GhosttyKit as the underlying terminal.

### Core Data Flow

```
AppFeature (root TCA store)
├─ RepositoriesFeature (repos, worktrees, PR state, archive/delete flows)
├─ CommandPaletteFeature
├─ SettingsFeature (general, notifications, coding agents, shortcuts, github, worktree, repo settings)
└─ UpdatesFeature (Sparkle auto-updates)

WorktreeTerminalManager (global @Observable terminal state)
├─ selectedWorktreeID (tracks current selection for bell logic)
└─ WorktreeTerminalState (per worktree)
    └─ TerminalTabManager (tab/split management)
        └─ GhosttySurfaceState[] (one per terminal surface)

WorktreeInfoWatcherManager (global worktree watcher state)
├─ HEAD watchers per worktree
└─ debounced branch / file / pull request refresh events

GhosttyRuntime (shared runtime)
└─ ghostty_app_t (single C instance)
    └─ ghostty_surface_t[] (independent terminal sessions)
```

### TCA ↔ Terminal Communication

The terminal layer (`WorktreeTerminalManager`) is `@Observable` but outside TCA. Communication uses `TerminalClient`:

```
Reducer → terminalClient.send(Command) → WorktreeTerminalManager
                                                    ↓
Reducer ← .terminalEvent(Event) ← AsyncStream<Event>
```

- **Commands**: tab creation, initial-tab setup, blocking scripts, search, Ghostty binding actions, tab/surface closing, notification toggles, and lifecycle management
- **Events**: notifications, dock indicator count changes, tab/focus changes, task status changes, blocking-script completion, command palette requests, and setup-script consumption
- Wired in `supacodeApp.swift`, subscribed in `AppFeature.appLaunched`

Worktree metadata refresh uses `WorktreeInfoWatcherClient` in parallel:

```
Reducer → worktreeInfoWatcher.send(Command) → WorktreeInfoWatcherManager
                                                           ↓
Reducer ← .repositories(.worktreeInfoEvent(Event)) ← AsyncStream<Event>
```

- **Commands**: `setWorktrees`, `setSelectedWorktreeID`, `setPullRequestTrackingEnabled`, `stop`
- **Events**: `branchChanged`, `filesChanged`, `repositoryPullRequestRefresh`
- Wired in `supacodeApp.swift`, subscribed in `AppFeature.appLaunched`

### Key Dependencies

- **TCA (swift-composable-architecture)**: App state, reducers, side effects
- **GhosttyKit**: Terminal emulator (built from Zig source in ThirdParty/ghostty)
- **Sparkle**: Auto-update framework
- **swift-dependencies**: Dependency injection for TCA clients
- **PostHog**: Analytics
- **Sentry**: Error tracking

## Ghostty Keybindings Handling

- Ghostty keybindings are handled via runtime action callbacks in `GhosttySurfaceBridge`, not by app menu shortcuts.
- App-level tab actions should be triggered by Ghostty actions (`GHOSTTY_ACTION_NEW_TAB` / `GHOSTTY_ACTION_CLOSE_TAB`) to honor user custom bindings.
- `GhosttySurfaceView.performKeyEquivalent` routes bound keys to Ghostty first; only unbound keys fall through to the app.

## Code Guidelines

- Target macOS 26.0+, Swift 6.0
- Before doing a big feature or when planning, consult with pfw (pointfree) skills on TCA, Observable best practices first.
- Use `@ObservableState` for TCA feature state; use `@Observable` for non-TCA shared stores; never `ObservableObject`
- Always mark `@Observable` classes with `@MainActor`
- Modern SwiftUI only: `foregroundStyle()`, `NavigationStack`, `Button` over `onTapGesture()`
- When a new logic changes in the Reducer, always add tests
- In unit tests, never use `Task.sleep`; use `TestClock` (or an injected clock) and drive time with `advance`.
- Prefer Swift-native APIs over Foundation where they exist (e.g., `replacing()` not `replacingOccurrences()`)
- Avoid `GeometryReader` when `containerRelativeFrame()` or `visualEffect()` would work
- Do not use NSNotification to communicate between reducers.
- Prefer `@Shared` directly in reducers for app storage and shared settings; do not introduce new dependency clients solely to wrap `@Shared`.
- Use `SupaLogger` for all logging. Never use `print()` or `os.Logger` directly. `SupaLogger` prints in DEBUG and uses `os.Logger` in release.

### Formatting & Linting

- 2-space indentation, 120 character line length (enforced by `.swift-format.json`)
- Trailing commas are mandatory (enforced by `.swiftlint.yml`)
- SwiftLint runs in strict mode; never disable lint rules without permission
- Custom SwiftLint rule: `store_state_mutation_in_views` — do not mutate `store.*` directly in view files; send actions instead

## UX Standards

- Buttons must have tooltips explaining the action and associated hotkey
- Use Dynamic Type, avoid hardcoded font sizes
- Components should be layout-agnostic (parents control layout, children control appearance)
- Never use custom colors, always use system provided ones.
- We use `.monospaced()` modifier on fonts when appropriate

## Rules

- After a task, ensure the app builds: `make build-app`
- Automatically commit your changes and your changes only. Do not use `git add .`
- Before you go on your task, check the current git branch name, if it's something generic like an animal name, name it accordingly. Do not do this for main branch
- After implementing an execplan, always submit a PR if you're not in the main branch

## Submodules

- `ThirdParty/ghostty` (`https://github.com/ghostty-org/ghostty`): Source dependency used to build `Frameworks/GhosttyKit.xcframework` and terminal resources.
- `Resources/git-wt` (`https://github.com/khoi/git-wt.git`): Bundled `wt` CLI used by Supacode Git worktree flows at runtime.
