#!/bin/bash
# Build the CURRENT branch's app and launch it as an ISOLATED PREVIEW instance
# (distinct bundle id + sandbox HOME) so you can eyeball UI/behaviour changes
# WITHOUT touching your real Supacool's data, prefs, or running session.
# See AGENTS.md -> "Previewing a branch as a second instance".
#
# Usage: scripts/build-and-preview.sh [repo-root-to-seed-on-the-preview-board]
#   First run is slow (full Swift build); re-runs after an edit are incremental.
#   Requires Frameworks/GhosttyKit.xcframework (run `make build-ghostty-xcframework`
#   once, or copy it from another checkout with the same submodule SHA).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="$ROOT/build/dd/Build/Products/Debug/Supacool.app"
PREVIEW_BUNDLE_ID="io.morethan.supacool.preview"
PREVIEW_BUNDLE_NAME="Supacool-Preview"
SEED_REPO="${1:-}"
LOG=/tmp/supacool-preview-build.log

if [ ! -d "$ROOT/Frameworks/GhosttyKit.xcframework" ]; then
  echo "error: Frameworks/GhosttyKit.xcframework missing."
  echo "       run 'make build-ghostty-xcframework' once (needs the Metal Toolchain),"
  echo "       or copy it from a checkout with the same ThirdParty/ghostty SHA."
  exit 1
fi

echo "[1/4] building (Debug, isolated DerivedData)…"
# Resolve SPM packages into a repo-local cache (gitignored under build/), not a
# shared /tmp or ~/Library dir. A shared cache can carry stale workspace-state
# pointing at half-extracted binary xcframeworks (Sentry / Sparkle missing
# Info.plist), failing the build with a baffling "There is no Info.plist found
# at …". Per-checkout keeps it reproducible.
xcodebuild -project supacool.xcodeproj -scheme supacool -configuration Debug build \
  -skipMacroValidation \
  -clonedSourcePackagesDirPath "$ROOT/build/spm-cache" \
  -derivedDataPath build/dd > "$LOG" 2>&1
grep -qE "BUILD SUCCEEDED" "$LOG" || { echo "BUILD FAILED — last errors:"; grep -n "error:" "$LOG" | tail -15; exit 1; }
echo "      BUILD SUCCEEDED"

# Re-stamping the bundle id is what isolates UserDefaults (cfprefsd keys by it).
# A fresh xcodebuild always resets it to io.morethan.supacool, so re-do each run.
# Brace the expansion: under a non-UTF-8 locale (this machine's setlocale
# falls back to C), bash's bare `$VAR…` greedily eats the multibyte ellipsis
# into the variable name and `set -u` then aborts on the bogus name.
echo "[2/4] re-stamp bundle id -> ${PREVIEW_BUNDLE_ID}…"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $PREVIEW_BUNDLE_ID" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $PREVIEW_BUNDLE_NAME" "$APP/Contents/Info.plist" 2>/dev/null || true

echo "[3/4] re-sign ad-hoc (Info.plist edit broke the seal)…"
codesign --force --deep --sign - --preserve-metadata=entitlements,flags "$APP" >/dev/null 2>&1

echo "[4/4] relaunch preview…"
pkill -f "build/dd/Build/Products/Debug/Supacool.app/Contents/MacOS/Supacool" 2>/dev/null || true
sleep 1
"$ROOT/scripts/preview-isolated.sh" "$APP" "$SEED_REPO" >/dev/null 2>&1 &
disown
sleep 3
echo "preview pid: $(pgrep -f 'build/dd/Build/Products/Debug/Supacool.app/Contents/MacOS/Supacool' || echo '<not up>')"
