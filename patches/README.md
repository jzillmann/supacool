# ghostty patches

`ThirdParty/ghostty` stays pinned to an upstream commit. The patches in this
directory are applied on top of that checkout by `make patch-ghostty`, which
every `make build-ghostty-xcframework` runs first. Nothing here is committed
into the submodule, so `upstream-cherry-pick` and submodule bumps keep working
as before — the submodule's working tree is simply dirty after a build.

Apply is idempotent: a patch that already applies in reverse is skipped.

## Files

| Patch | What it does |
|---|---|
| `ghostty-link-config.patch` | Implements `RepeatableLink.parseCLI` / `formatEntry` so the documented `link` config option can actually be set (upstream ships it with `TODO: This can't currently be set!` and a `error.NotImplemented` parser). Supacool needs it to highlight ticket ids like `CEN-9398` in terminal output — see `TerminalLinkRules`. |

## After a submodule bump

If `make patch-ghostty` fails, the patch needs a rebase:

```bash
git -C ThirdParty/ghostty apply --3way patches/ghostty-link-config.patch   # fix conflicts
git -C ThirdParty/ghostty diff > patches/ghostty-link-config.patch          # re-cut
```

A patch that upstream has since implemented itself should just be deleted.
