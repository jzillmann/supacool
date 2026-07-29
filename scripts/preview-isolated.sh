#!/bin/bash
# Launch an already-built Supacool.app as a throwaway PREVIEW instance that is
# fully detached from your real Supacool:
#   - -SupacoolDataDirectory launch arg  -> isolated ~/.supacool data. This is
#     the mechanism that actually isolates app data: Foundation's
#     homeDirectoryForCurrentUser IGNORES the $HOME env var, so the old
#     HOME-only redirect silently pointed previews at the REAL ~/.supacool
#     (and the single-instance guard then blocked them).
#   - HOME redirected to a sandbox dir   -> isolates ~/Library odds and ends
#     plus anything env-based spawned inside preview terminals
#   - all SUPACOOL_* env vars stripped    -> no hook-socket cross-talk if launched
#                                            from inside a Supacool terminal
# NOTE: UserDefaults is keyed by bundle id via cfprefsd (ignores $HOME), so true
# isolation also requires the app to carry a distinct bundle id. build-and-preview.sh
# re-stamps it to io.morethan.supacool.preview before calling this.
#
# Usage: scripts/preview-isolated.sh /path/to/Supacool.app [repo-root-to-seed]
set -euo pipefail
APP="${1:?usage: preview-isolated.sh /path/to/Supacool.app [repo-root]}"
SEED_REPO="${2:-}"
SANDBOX="$HOME/.supacool-preview-sandbox"
mkdir -p "$SANDBOX/.supacool"

# Seed the sandbox's ~/.claude with the real settings on first run. Agents
# spawned inside the preview run with HOME=$SANDBOX and read
# $SANDBOX/.claude/settings.json — without the Supacool hook entries there,
# preview agents emit NO hooks at all: no busy tracking, no session-id
# capture, no multi-agent adoption. The hook commands are env-guarded
# (SUPACOOL_*), so seeding them is inert outside Supacool terminals.
if [ -f "$HOME/.claude/settings.json" ] && [ ! -f "$SANDBOX/.claude/settings.json" ]; then
  mkdir -p "$SANDBOX/.claude"
  cp "$HOME/.claude/settings.json" "$SANDBOX/.claude/settings.json"
fi

# Seed a single repo onto the preview board on first run only, so sessions you
# create in the preview survive relaunches. Delete the sandbox to start fresh.
if [ -n "$SEED_REPO" ] && [ ! -f "$SANDBOX/.supacool/settings.json" ]; then
  printf '{\n  "repositoryRoots": ["%s"]\n}\n' "$SEED_REPO" > "$SANDBOX/.supacool/settings.json"
fi

# Strip agent-session markers along with SUPACOOL_*: a preview launched
# from inside ANY agent terminal (Supacool's or a bare claude/codex shell)
# would otherwise leak them into every PTY the preview spawns. Concretely,
# an inherited CLAUDE_CODE_CHILD_SESSION makes claudes inside the preview
# skip transcript saving — their conversations are never written, and a
# later Resume reports "No conversation found" (observed 2026-07-29).
for v in $(env | sed -nE 's/^(SUPACOOL_[A-Z_]*|CLAUDE[A-Z_]*|CODEX[A-Z_]*)=.*/\1/p'); do
  unset "$v"
done
exec env HOME="$SANDBOX" "$APP/Contents/MacOS/Supacool" \
  -SupacoolDataDirectory "$SANDBOX/.supacool"
