# Build and run

## First-time setup

```bash
brew install mise librsvg       # librsvg only if you want to regenerate the icon
cd /path/to/supacool
mise trust                      # approve ~/.local/share/mise managing this dir
mise install                    # pulls zig 0.16.0, swiftlint, xcsift, create-dmg
```

## Every build

```bash
make build-ghostty-xcframework  # zig → Frameworks/GhosttyKit.xcframework
make build-app                  # debug build
make run-app                    # build + launch with log stream
make test                       # full test suite
make check                      # swift-format + swiftlint
```

## Debug vs Release — which to actually run

`build-app` / `run-app` build **Debug**, which is `SWIFT_OPTIMIZATION_LEVEL = -Onone`
and `GCC_OPTIMIZATION_LEVEL = 0`. That is fine for iterating, but it is the wrong
build to *live* in: Supacool's hot path is ghostty's `backend.kqueue.Loop.tick`
multiplexing one PTY per session, plus a `termio.Exec.ReadThread` per terminal.
With a large board that loop is hot continuously, and unoptimized code multiplies
its cost — a fleet of dozens of chatty agent sessions can push the app to several
hundred percent CPU.

```bash
make build-app-release          # optimized build
make run-app-release            # optimized build + launch
make install-release-build      # optimized build → /Applications
```

These pass `ONLY_ACTIVE_ARCH=YES`: the Release configuration otherwise builds a
universal binary, which only matters for distribution (`make archive`).

They also pass `ENABLE_HARDENED_RUNTIME=NO`, and that one is load-bearing. The
Release configuration turns the hardened runtime on, which enables **library
validation**: every embedded framework must then carry the same Team ID as the main
executable. A local build is ad-hoc signed and therefore has *no* Team ID, so dyld
refuses to map `Sparkle.framework` and the app is killed before `main()` with

```
Library not loaded: @rpath/Sparkle.framework/Versions/B/Sparkle
Reason: … mapping process and mapped file (non-platform) have different Team IDs
```

which surfaces as the macOS "Supacool cannot be opened because of a problem" dialog.
Check with `codesign -dv --verbose=2 <app>`: a good local build reads `flags=0x2(adhoc)`,
a broken one `flags=0x10002(adhoc,runtime)`. `archive` keeps the hardened runtime on
purpose — it signs with a real Developer ID, which notarization requires.

Note the single-instance guard: quit a running Supacool before launching another
build of it, or the second one exits with the "already running" alert.

**Concurrent builds collide.** Every one of these targets shares the same
DerivedData, and Xcode takes an exclusive lock on `XCBuildData/build.db`. Two
sessions running `make build-app` at once fail with `unable to attach DB … database
is locked`. That is not a corrupt checkout — it is contention. Either serialize the
builds or give one a private `-derivedDataPath` (which is exactly why the
`only-Supacool-tests` invocation below pins its own).

`run-app` uses `xcodebuild -showBuildSettings` to derive the current `FULL_PRODUCT_NAME` dynamically — so even though Supacool renamed `PRODUCT_NAME` from `$(TARGET_NAME)` to a literal `Supacool`, the makefile finds `Supacool.app` automatically and launches it.

## The Metal Toolchain trap

**Symptom**:
```
error: cannot execute tool 'metal' due to missing Metal Toolchain;
       use: xcodebuild -downloadComponent MetalToolchain
```

**Cause**: the Metal Toolchain is a **hard prerequisite for the macOS build**, not an iOS-only concern. `MetallibStep` is wired into `src/build/SharedDeps.zig`, so ghostty compiles `src/renderer/shaders/shaders.metal` via `xcrun metal` for the *native macOS* slice. Since Xcode 26 the Metal Toolchain ships as a separately-downloadable component: the `metal` binary is present as a shim at `$(xcrun -f metal)` and errors out until you download the component.

**The fix is to download it** — one-time, ~1GB, machine-wide:

```bash
xcodebuild -downloadComponent MetalToolchain
```

**Confirm it's an environment problem, not a ghostty problem**, before touching build flags — compile a trivial shader with no ghostty involved:

```bash
printf '#include <metal_stdlib>\nkernel void k() {}\n' > /tmp/probe.metal
xcrun -sdk macosx metal -c /tmp/probe.metal -o /tmp/probe.ir
```

If that fails, every ghostty pin fails the same way and no zig flag will help.

> ⚠️ This page previously claimed `-Dxcframework-target=native` avoided the Metal Toolchain dependency by skipping the iOS slices. **That was wrong** — the macOS slice compiles Metal shaders too. Corrected 2026-08-14 after a rebuild on Xcode 26.5 failed at `metal Ghostty (Ghostty.ir)` with 207/217 steps already succeeded.

**`-Dxcframework-target=native` is still worth keeping**, just for a different reason: it emits only the macOS slice, so the build is faster. `ThirdParty/ghostty/src/build/Config.zig` defines the flag. Note that upstream has since removed iOS from the full Ghostty build entirely — only `libghostty-vt` targets iOS now (`-Demit-lib-vt`) — so the flag saves less than it used to.

## Product naming

- Xcode project: `supacool.xcodeproj`. Targets: `supacool` (app) and `supacoolTests` (tests).
- `PRODUCT_NAME = Supacool` → built bundle is `Supacool.app`, executable `Contents/MacOS/Supacool`.
- `CFBundleDisplayName`, `CFBundleName`: `Supacool`.
- `CFBundleIdentifier`: `io.morethan.supacool` — distinct from upstream `supabitapp/supacode`'s bundle ID so both can coexist on the same machine.
- **Source directories on disk** are still named `supacode/` and `supacodeTests/` — kept deliberately as historical markers for code originally derived from the fork. File-path references in docs and build settings (`supacode/Info.plist`, `supacode/supacool.entitlements`) use these legacy names.

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
xcodebuild test -project supacool.xcodeproj -scheme supacool \
  -destination "platform=macOS" \
  -only-testing:supacoolTests/BoardFeatureTests \
  -only-testing:supacoolTests/NewTerminalFeatureTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  -skipMacroValidation 2>&1 | tee /tmp/supacool-tests.log | \
  grep -E "Test case|TEST (SUCCEEDED|FAILED)" | tail -30
```

The `| tail -80` pattern some Makefiles use buffers all output until completion — `tee` + `grep` is better if you want to follow progress live.

Test bundle flakiness: the upstream `AppFeatureCommandPaletteTests`, `WorktreeTerminalManagerTests`, and a few `DeeplinkClientTests` sometimes fail at 0.000 seconds due to test-bundle-loading issues. These are environmental, not regressions from Supacool changes. Re-run full suite with `make test` and they usually pass.

**Tests while the app is running**: the tests are hosted *in* the app, and LaunchServices refuses to launch the test host while another instance of `io.morethan.supacool` is running — `xcodebuild` fails with `Could not launch "supacoolTests" … The LaunchServices launcher has returned an error`, even from a separate `-derivedDataPath`. `make test` handles this for you: it builds into `build/dd-tests` under bundle id `io.morethan.supacool.tests`, so a live app never blocks the runner. When invoking `xcodebuild test` directly, apply the same two overrides yourself. Don't quit the user's app (live sessions!) — give the test build its own bundle id instead:

```bash
xcodebuild test -project supacool.xcodeproj -scheme supacool \
  -destination "platform=macOS" \
  -derivedDataPath build/dd-tests \
  -clonedSourcePackagesDirPath build/spm-cache \
  -only-testing:supacoolTests/<YourSuite> \
  -parallel-testing-enabled NO \
  'PRODUCT_BUNDLE_IDENTIFIER=io.morethan.tests.$(TARGET_NAME)' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  -skipMacroValidation
```

The `$(TARGET_NAME)` reference keeps the app and test-bundle ids distinct. Side effect: `UserDefaults` reads from a fresh prefs domain, which is extra isolation, not a problem, for unit tests.

## Logs

```bash
make log-stream   # streams io.morethan.supacool subsystem
```

Uses `log stream --predicate 'subsystem == "io.morethan.supacool"'`. If you see nothing, check that the running app's bundle ID actually is `io.morethan.supacool` (via `plutil -p <path>/Contents/Info.plist | grep Identifier`).

## Clean rebuild

If builds get weird after pulling upstream or switching branches:

```bash
rm -rf /Users/jz/Library/Developer/Xcode/DerivedData/supacool-* /Users/jz/Library/Developer/Xcode/DerivedData/supacode-*
make build-app
```

The DerivedData hash doesn't change when the repo directory or target name changes, so nuking derived data is the safe default for "builds are acting stale."
