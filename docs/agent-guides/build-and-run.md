# Build and run

## First-time setup

```bash
brew install mise librsvg       # librsvg only if you want to regenerate the icon
cd /path/to/supacool
mise trust                      # approve ~/.local/share/mise managing this dir
mise install                    # pulls zig 0.15.2, swiftlint, xcsift, create-dmg
```

## Every build

```bash
make build-ghostty-xcframework  # zig → Frameworks/GhosttyKit.xcframework
make build-app                  # debug build
make run-app                    # build + launch with log stream
make test                       # full test suite
make check                      # swift-format + swiftlint
```

`run-app` uses `xcodebuild -showBuildSettings` to derive the current `FULL_PRODUCT_NAME` dynamically — so even though Supacool renamed `PRODUCT_NAME` from `$(TARGET_NAME)` to a literal `Supacool`, the makefile finds `Supacool.app` automatically and launches it.

## The Metal Toolchain trap

**Symptom**:
```
error: cannot execute tool 'metal' due to missing Metal Toolchain;
       use: xcodebuild -downloadComponent MetalToolchain
```

**Cause**: upstream ghostty builds a universal xcframework (macOS + iOS + iOS-sim slices) by default. Xcode 26 ships the iOS Metal Toolchain as a separately-downloadable component. Even with the toolchain installed, the build is slower than necessary for a macOS-only app.

**Supacool's fix** is already applied — the Makefile's `build-ghostty-xcframework` rule passes `-Dxcframework-target=native` to the zig build, which emits only the macOS slice. `ThirdParty/ghostty/src/build/Config.zig:140` defines the flag; `ThirdParty/ghostty/src/build/GhosttyXCFramework.zig:80` switches on it. No iOS compilation, no Metal Toolchain dependency.

**If you still hit the error** after all that — e.g. ghostty's upstream changed the build config in a merge — the fallback is:

```bash
xcodebuild -downloadComponent MetalToolchain
```

…which installs the iOS Metal Toolchain (one-time, ~1GB) and lets the universal build complete. Prefer fixing the zig flag; only download as a workaround.

## The supacode → Supacool product name

`PRODUCT_NAME` in the main target's build config is set to the literal `Supacool` (not `$(TARGET_NAME)`). Consequences:

- The built bundle is `Supacool.app` (instead of `supacode.app`).
- `CFBundleName` synthesized from `PRODUCT_NAME` is `Supacool` — this is what the macOS menu bar shows.
- `CFBundleDisplayName` is also `Supacool` (set both in Info.plist and via `INFOPLIST_KEY_CFBundleDisplayName`).
- `CFBundleIdentifier` is `app.morethan.supacool` (so stock supacode and Supacool can coexist on the same machine without collision).
- Internally, the Xcode target is still named `supacode` and the sources live under `supacode/`. That's a holdover from the fork era — kept because mass renaming is cosmetic and disruptive (Xcode project regeneration, asset paths, log subsystem) without changing behaviour.

## App icon regeneration

Source: `Supacool/assets/app-icon.svg`. To regenerate PNGs at all macOS icon sizes:

```bash
cd supacode/Assets.xcassets/AppIcon.appiconset/
for pair in \
  "16:appicon-macOS-Dark-16x16@1x.png" \
  "32:appicon-macOS-Dark-16x16@2x.png" \
  "32:appicon-macOS-Dark-32x32@1x.png" \
  "64:appicon-macOS-Dark-32x32@2x.png" \
  "128:appicon-macOS-Dark-128x128@1x.png" \
  "256:appicon-macOS-Dark-256x256@1x.png" \
  "512:appicon-macOS-Dark-512x512@1x.png" \
  "1024:appicon-macOS-Dark-1024x1024@1x.png"; do
  size="${pair%%:*}"; name="${pair#*:}"
  rsvg-convert -w "$size" -h "$size" -o "$name" ../../../../Supacool/assets/app-icon.svg
done
```

Worth turning into a `make icon` target if tweaking frequently.

## Tests

Full suite:

```bash
make test
```

Supacool-only tests (faster):

```bash
xcodebuild test -project supacode.xcodeproj -scheme supacode \
  -destination "platform=macOS" \
  -only-testing:supacodeTests/BoardFeatureTests \
  -only-testing:supacodeTests/NewTerminalFeatureTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  -skipMacroValidation 2>&1 | tee /tmp/supacool-tests.log | \
  grep -E "Test case|TEST (SUCCEEDED|FAILED)" | tail -30
```

The `| tail -80` pattern some Makefiles use buffers all output until completion — `tee` + `grep` is better if you want to follow progress live.

Test bundle flakiness: the upstream `AppFeatureCommandPaletteTests`, `WorktreeTerminalManagerTests`, and a few `DeeplinkClientTests` sometimes fail at 0.000 seconds due to test-bundle-loading issues. These are environmental, not regressions from Supacool changes. Re-run full suite with `make test` and they usually pass.

## Logs

```bash
make log-stream   # streams app.morethan.supacool subsystem
```

Uses `log stream --predicate 'subsystem == "app.morethan.supacool"'`. If you see nothing, check that the running app's bundle ID actually is `app.morethan.supacool` (via `plutil -p <path>/Contents/Info.plist | grep Identifier`).

## Clean rebuild

If builds get weird after pulling upstream or switching branches:

```bash
rm -rf /Users/jz/Library/Developer/Xcode/DerivedData/supacode-*
make build-app
```

The DerivedData hash doesn't change when the repo directory or target name changes, so nuking derived data is the safe default for "builds are acting stale."
