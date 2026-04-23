# Supacool

Native terminal coding agents command center.

![screenshot](https://www.supacode.sh/screenshot.png)

## Features

Supacool started life as a fork of [supacode](https://github.com/supabitapp/supacode) and is now an independently maintained derivative. Same native-Mac soul, a very different day-to-day feel.

**Inherited from supacode:**

- Native macOS terminal powered by [Ghostty](https://github.com/ghostty-org/ghostty)
- Git worktree creation and management per session
- GitHub pull-request integration (status, merge, review)
- Command palette for quick navigation
- First-class support for Claude Code, Codex, and plain shell sessions
- Sparkle auto-updates

**New in Supacool:**

- **Matrix Board** — a Kanban-style grid of agent sessions replacing the sidebar, with "Waiting on Me" and "In Progress" buckets at a glance
- **Full-screen terminal per session** with inline diff-tool, split-shell (⌘E to toggle), and session-info affordances
- **Auto-resume** — sessions survive app restarts and upgrades; no more losing a running agent to a relaunch
- **Park / unpark** — free the PTY but keep the session metadata, and bring it back with one click when you're ready
- **⌘⌥-arrow session switcher** — ⌘-Tab-style overlay that cycles through sessions, grouped by Waiting and Working (⌥ added to the combo so it doesn't shadow the terminal's own line-navigation shortcuts)
- **New session from a pasted PR URL** — paste a GitHub PR URL into the New Terminal prompt and Supacool matches the repo, forces worktree mode, and pre-fills the PR's head branch; press Create and you're in
- **Unified workspace picker** — one search combo box covering repo root, existing worktrees, local + remote branches, and new-branch creation
- **AI-assisted branch names** — a wand button in the workspace picker generates a kebab-case branch name from the session prompt
- **Skill autocomplete in the prompt** — type `/` (Claude Code) or `$` (Codex) to browse and insert project and user skills inline
- **Auto-Observer** — per-session idle watcher that uses a small LLM to auto-respond to obvious prompts, so overnight runs don't stall on a yes/no dialog
- **Ticket & PR chips** — Linear ticket ids and GitHub PR URLs are parsed from the session transcript and surfaced on the card as clickable chips
- **Pre-worktree fetch** so fresh branches are based on the actually-latest upstream, not your local cache
- **Setup-script env vars** (`SUPACODE_REPO_ROOT`, `SUPACODE_WORKTREE_ROOT`) let your repo's own CLIs orient themselves from inside a freshly-created worktree

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

