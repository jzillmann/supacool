# Supacool — supacode fork

Personal macOS terminal built on a fork of [`supabitapp/supacode`](https://github.com/supabitapp/supacode). Source lives on the `supacool` branch of this repo; the `main` branch tracks upstream bit-identically so `git pull upstream main` stays clean.

## Repo layout

- `supacode/` — the upstream Swift sources. Synchronized folder in the Xcode target.
- `supacode/Supacool/` — **Supacool's own Swift code** (new domain types, reducers, views). Auto-compiled as a subtree of the synchronized group. New code goes here.
- `supacode.xcodeproj/` — the Xcode project.
- `Supacool/assets/` — non-code assets (app icon SVG).
- `Supacool/docs/` — developer conventions + design notes (start here if you're joining).
- `ThirdParty/ghostty/` — Ghostty submodule, compiled into `GhosttyKit.xcframework`.

## Conventions

- [Persistence convention](docs/persistence-convention.md) — every Supacool Codable struct that lands on disk uses a manual `init(from decoder:)` with `decodeIfPresent ?? default`. Synthesized Codable is BANNED for persisted types because it wipes user data on any field addition. Mandatory reading before touching anything under `supacode/Supacool/Features/Board/Persistence/` or `supacode/Supacool/Domain/`.

## Build

- `make build-ghostty-xcframework` — build `GhosttyKit.xcframework` from the submodule (macOS-only slice via `-Dxcframework-target=native`).
- `make build-app` — debug build.
- `make run-app` — build + launch, streaming logs.
- `make test` — full test suite.

## Branch strategy

- `main` — read-only mirror of upstream `supabitapp/supacode`. Receives `git pull upstream main` fast-forwards.
- `supacool` — personal work, periodically `git rebase main` onto upstream HEAD.

```
git checkout main && git pull upstream main && git push origin main
git checkout supacool && git rebase main
```
