# Supacool

Native terminal coding agents command center.

![screenshot](https://www.supacode.sh/screenshot.png)

## Features

Supacool is a fork of [supacode](https://github.com/supabitapp/supacode) — but turned up to eleven. Same native-Mac soul, a very different day-to-day feel.

**Inherited from supacode:**

- Native macOS terminal powered by [Ghostty](https://github.com/ghostty-org/ghostty)
- Git worktree creation and management per session
- GitHub pull-request integration (status, merge, review)
- Command palette for quick navigation
- First-class support for Claude Code, Codex, and plain shell sessions
- Sparkle auto-updates

**New in Supacool:**

- **Matrix Board** — a Kanban-style grid of agent sessions replacing the sidebar, with "Waiting on Me" and "In Progress" buckets at a glance
- **Auto-resume** — sessions survive app restarts and upgrades; no more losing a running agent to a relaunch
- **Park / unpark** — free the PTY but keep the session metadata, and bring it back with one click when you're ready
- **Full-screen terminal per session** with inline diff-tool, split-shell, and session-info affordances
- **⌘-arrow session switcher** — ⌘-Tab-style overlay that cycles through sessions, grouped by Waiting and Working
- **Pre-worktree fetch** so fresh branches are based on the actually-latest upstream, not your local cache

## Technical Stack

- [The Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture)
- [libghostty](https://github.com/ghostty-org/ghostty)

## Requirements

- macOS 26.0+
- [mise](https://mise.jdx.dev/) (for dependencies)

## Building

```bash
make build-ghostty-xcframework   # Build GhosttyKit from Zig source
make build-app                   # Build macOS app (Debug)
make run-app                     # Build and launch
```

## Development

```bash
make check     # Run swiftformat and swiftlint
make test      # Run tests
make format    # Run swift-format
```

## Contributing

- I actual prefer a well written issue describing features/bugs u want rather than a vibe-coded PR
- I review every line personally and will close if I feel like the quality is not up to standard

