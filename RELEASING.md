# Releasing Supacool

This doc describes how to cut a release, how auto-updates work, and the one-time migration steps for anyone moving from an older `~/.supacode` install.

## TL;DR

```bash
make bump-and-release        # bumps MARKETING_VERSION + BUILD, tags, pushes, opens release notes editor
```

That triggers [`.github/workflows/release.yml`](.github/workflows/release.yml) on `release: [published]`, which builds, notarizes, DMG-wraps, and uploads artifacts to the GitHub release it was fired from.

Every push to `main` additionally triggers [`.github/workflows/release-tip.yml`](.github/workflows/release-tip.yml), which publishes a rolling pre-release under the `tip` tag.

## Auto-update architecture

Supacool uses [Sparkle 2.9](https://sparkle-project.org) for in-app auto-updates.

- **Feed URL** (`Info.plist` → `SUFeedURL`): `https://github.com/jzillmann/supacool/releases/latest/download/appcast.xml`
  - GitHub redirects `/releases/latest/download/<asset>` to whichever release has the `latest` flag, so the URL stays stable across releases.
- **Appcast hosting**: `appcast.xml` is attached as an asset on every stable release. The `release.yml` job runs [`bins/generate_appcast`](bins/generate_appcast) (Sparkle's signing tool) to produce it, including up to 10 historical versions with binary deltas.
- **Signature verification**: Sparkle validates each `<item>` in the appcast against an EdDSA signature, using `SUPublicEDKey` from `Info.plist`. The matching private key lives as the `SPARKLE_PRIVATE_KEY` secret on `jzillmann/supacool` in GitHub Actions.
- **Channels**: stable releases live on tagged versions (`v0.9.0`, …). Tip builds live on a force-moved `tip` tag; the tip appcast is merged into the stable appcast on each tip build so clients subscribed to the tip channel (via UpdatesFeature) see new builds without a separate feed URL.

## One-time setup: Sparkle EdDSA keypair (PENDING — Johannes must do this before the first Supacool release)

The current `SUPublicEDKey` in `supacode/Info.plist` is **inherited from supabitapp/supacode**. We do not have the matching private key, so we cannot sign appcasts that Sparkle will accept. Before cutting the first Supacool release:

1. Generate a fresh keypair using the Sparkle CLI:
   ```bash
   # Install Sparkle if needed: brew install --cask sparkle
   # Or extract generate_keys from the Sparkle release: https://github.com/sparkle-project/Sparkle/releases
   generate_keys                # prints the EdDSA public key; stores private key in the macOS keychain
   generate_keys -p             # prints the public key again
   generate_keys -x private.key # exports the private key to a file
   ```
2. Put the **public key** into `supacode/Info.plist` as the value of `<key>SUPublicEDKey</key>` (replacing the supabitapp placeholder and removing the TODO comment above it). Commit.
3. Put the **private key** into the `SPARKLE_PRIVATE_KEY` GitHub Actions secret on `jzillmann/supacool` (Settings → Secrets and variables → Actions → New repository secret).
4. Back the private key up in 1Password (or whatever password vault you use). If it's ever lost, every installed client will have to be manually repointed at a new public key via a ship-a-new-release-from-a-new-codepath migration — there is no recovery.
5. Delete `private.key` from disk.

Until steps 2 and 3 are done, releases built by CI will produce an appcast signed with whatever is in `SPARKLE_PRIVATE_KEY`, and installed clients will reject the update because the signature won't match the stale public key in `Info.plist`. The only user-visible symptom is "Check for Updates" silently reporting up-to-date while Console shows a Sparkle signature error.

## Other required GitHub Actions secrets

Already configured on the upstream repo; copy over to `jzillmann/supacool` if CI fails with "secret not set":

- `DEVELOPER_ID_CERT_P12` — base64-encoded Developer ID Application cert export.
- `DEVELOPER_ID_CERT_PASSWORD` — password for the `.p12`.
- `DEVELOPER_ID_IDENTITY` — e.g. `Developer ID Application: Johannes Zillmann (TEAMID)`.
- `KEYCHAIN_PASSWORD` — arbitrary, picks a password for the temporary CI keychain.
- `APPLE_TEAM_ID`, `APPLE_NOTARIZATION_ISSUER`, `APPLE_NOTARIZATION_KEY_ID`, `APPLE_NOTARIZATION_KEY` — App Store Connect API key for `notarytool`.
- `SPARKLE_PRIVATE_KEY` — see above.
- `SENTRY_DSN`, `SENTRY_AUTH_TOKEN`, `POSTHOG_API_KEY`, `POSTHOG_HOST` — telemetry. `SENTRY_PROJECT` is hardcoded in the workflow as `supacool`; make sure a matching Sentry project exists on the `supabit` org, or rename the project / update the workflow.
- `GH_RELEASE_TOKEN` — used by `release-tip.yml` to force-move the `tip` tag.

## Migration notes (one-time, per user)

Supacool's rename from `supacode` broke cleanly rather than carrying legacy aliases. Before first launch of a Supacool build, do this on each machine:

```bash
# Move your existing data dir so the renamed code picks it up.
[ -d ~/.supacode ] && mv ~/.supacode ~/.supacool

# Rename any per-repo settings files (repositories you've configured in Supacool).
# Adjust the search root if your repos live elsewhere:
fd --hidden --no-ignore -t f 'supacode.json' ~/Projects 2>/dev/null | while read f; do
  mv "$f" "$(dirname "$f")/supacool.json"
done
```

Other things that changed (update any personal scripts / shortcuts):

| Old | New |
|---|---|
| `supacode://…` deeplink | `supacool://…` |
| `SUPACODE_REPO_ID`, `_WORKTREE_ID`, `_TAB_ID`, `_SURFACE_ID`, `_SOCKET_PATH`, `_CLI_PATH`, `_WORKTREE_PATH`, `_ROOT_PATH`, `_REPO_ROOT` | `SUPACOOL_*` with the same suffix |
| `~/.supacode/` | `~/.supacool/` |
| `supacode.json` per-repo settings | `supacool.json` |

The app bundle is `Supacool.app` with executable `Contents/MacOS/Supacool` and bundle ID `io.morethan.supacool`. Source directories on disk are still named `supacode/` and `supacodeTests/` — deliberate historical markers for code originally derived from the upstream fork — but the Xcode project (`supacool.xcodeproj`), scheme, and targets (`supacool`, `supacoolTests`) are all renamed.

## Testing the update flow locally

1. Build and install a version that is behind the latest release:
   ```bash
   # Find the current latest version on GH:
   gh release list --limit 1 -R jzillmann/supacool
   # Bump your local MARKETING_VERSION to something LOWER than that:
   # (edit supacool.xcodeproj/project.pbxproj, e.g. MARKETING_VERSION = 0.7.0)
   make build-app
   make install-dev-build
   ```
2. Launch the installed build from `/Applications/Supacool.app` and trigger **Supacool → Check for Updates** (or wait — `SUEnableAutomaticChecks` is on).
3. Sparkle should fetch the appcast, verify against `SUPublicEDKey`, and offer the newer release.
4. Check `Console.app` with the subsystem filter `io.morethan.supacool` (or `make log-stream`) for Sparkle logs if the update is rejected.

## Release-flow cheat sheet

Bump the version and cut a tagged release:
```bash
make bump-version VERSION=0.9.0          # bumps MARKETING_VERSION, auto-increments BUILD, commits and tags locally
make bump-and-release VERSION=0.9.0      # same + pushes tag + opens editor for release notes and creates GH release
```

Inspect a CI run:
```bash
gh run list --workflow=release.yml
gh run watch
```

Re-run a failed release job after fixing something (e.g., missing secret) without re-tagging:
```bash
gh run rerun <run-id> --failed
```

If you need to rebuild artifacts for an already-published release, delete the existing assets on that release (so the workflow's `check` step lets the build proceed):
```bash
gh release view v0.9.0 --json assets --jq '.assets[].name' | xargs -I {} gh release delete-asset v0.9.0 {} -y
```
