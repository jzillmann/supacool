#!/bin/bash
# Launch an already-built Supacool.app as a throwaway PREVIEW instance that is
# fully detached from your real Supacool:
#   - HOME redirected to a sandbox dir   -> isolated ~/.supacool data + ~/Library
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

# Seed a single repo onto the preview board on first run only, so sessions you
# create in the preview survive relaunches. Delete the sandbox to start fresh.
if [ -n "$SEED_REPO" ] && [ ! -f "$SANDBOX/.supacool/settings.json" ]; then
  printf '{\n  "repositoryRoots": ["%s"]\n}\n' "$SEED_REPO" > "$SANDBOX/.supacool/settings.json"
fi

for v in $(env | sed -n 's/^\(SUPACOOL_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
exec env HOME="$SANDBOX" "$APP/Contents/MacOS/Supacool"
