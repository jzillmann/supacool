# Supacool

Personal macOS terminal. **Originally derived from [`supabitapp/supacode`](https://github.com/supabitapp/supacode)** at v0.8.0; since then it has evolved as an independently maintained codebase. License is FSL-1.1-ALv2 (inherited).

This is the master document for anyone (human or AI agent) working in this repo. `CLAUDE.md` is a symlink to this file, so Claude Code and other tooling read it by default.

---

## Read this first: the three things that bite

1. **The UI is not supacode's.** Supacool replaced the `NavigationSplitView(sidebar:, detail:)` layout with the **Matrix Board** — a grid of cards, each one a persistent agent session (claude-code or codex). The old sidebar/detail files still exist on disk but are orphaned (not wired to any Scene). Don't touch them expecting UI changes to take effect.

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
├── AGENTS.md                 # THIS FILE — master doc
├── CLAUDE.md → AGENTS.md     # symlink (Claude Code convention)
├── supacode/                 # app source (top-level dir name kept for historical reasons)
│   └── Supacool/             # net-new Supacool features (Board, AgentSession, etc.)
├── supacodeTests/            # tests, flat. BoardFeatureTests, NewTerminalFeatureTests, etc.
├── supacode.xcodeproj/       # Xcode project (objectVersion 77, synchronized root groups)
├── Supacool/                 # NON-code: assets (app-icon.svg) + README; NOT in Xcode target
├── docs/agent-guides/        # deep reference docs (start here when doing architecture work)
├── .claude/skills/           # Claude-invokable skill modules (recurring workflows)
├── ThirdParty/ghostty/       # Ghostty submodule → GhosttyKit.xcframework
└── Makefile                  # build-ghostty-xcframework, build-app, run-app, test, etc.
```

The split between `supacode/` (originally-supacode source) and `supacode/Supacool/` (net-new Supacool features) is a **convention, not a constraint** — a holdover from the fork era that helped keep merges clean. New code can live wherever it fits best architecturally; new top-level Supacool features generally still go under `supacode/Supacool/` for grouping.

---

## Branches and remotes

- **`main`** — the active branch. All work happens here (or on feature branches PR'd into it).
- **`upstream`** remote — `supabitapp/supacode`. Kept as a read-only reference for occasional cherry-pick raids when upstream ships something interesting (terminal/ghostty fixes, etc.). We do **not** track upstream live; pulls are deliberate, not routine. See [`docs/agent-guides/upstream-cherry-pick.md`](./docs/agent-guides/upstream-cherry-pick.md).
- **`origin`** remote — `jzillmann/supacool`.
- **`archive/upstream-mirror-v0.8.0`** tag — last commit where `main` mirrored upstream verbatim, kept for historical reference.

---

## What's in (recent) and what's explicitly out

**In, shipped:**
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
| Cherry-pick from upstream supacode | [`docs/agent-guides/upstream-cherry-pick.md`](./docs/agent-guides/upstream-cherry-pick.md) |
| Know what NOT to build | [`docs/agent-guides/out-of-scope.md`](./docs/agent-guides/out-of-scope.md) |
| Change `RemoteHost` / ssh_config handling | [`docs/agent-guides/remote-hosts.md`](./docs/agent-guides/remote-hosts.md) |
| Add a new feature end-to-end | Skill: [`.claude/skills/add-feature/SKILL.md`](./.claude/skills/add-feature/SKILL.md) |

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

The terminal layer (`WorktreeTerminalManager`) is `@Observable` but outside TCA. Communication uses `TerminalClient`: reducers send `Command`s in, receive `Event`s back via `AsyncStream`. Wired in `supacodeApp.swift`, subscribed in `AppFeature.appLaunched`.

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
- SwiftLint runs in strict mode; never disable lint rules without permission
- Custom SwiftLint rule: `store_state_mutation_in_views` — do not mutate `store.*` directly in view files; send actions instead

### UX standards

- Buttons must have tooltips explaining the action and associated hotkey
- Use Dynamic Type, avoid hardcoded font sizes
- Components should be layout-agnostic (parents control layout, children control appearance)
- Never use custom colors, always use system-provided ones
- Use `.monospaced()` modifier on fonts when appropriate

### Workflow rules

- After a task, ensure the app builds: `make build-app`
- Commit your changes only — do not use `git add .`
- Before starting work, check the current branch name; if it's something generic like an animal name, rename it appropriately. Do not do this for `main`.
- After implementing an execplan, submit a PR if you're not on `main`.

### Submodules

- `ThirdParty/ghostty` (`https://github.com/ghostty-org/ghostty`): source dependency used to build `Frameworks/GhosttyKit.xcframework` and terminal resources.
- `Resources/git-wt` (`https://github.com/khoi/git-wt.git`): bundled `wt` CLI used by Git worktree flows at runtime.

---

## License

FSL-1.1-ALv2 (inherited from supacode). Personal / internal use fine; auto-converts to Apache-2.0 in 2028.
