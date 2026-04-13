# Persistence convention — forward-compatible Codable

**Hard rule**: every Supacool struct that lands on disk via `@Shared` / `SharedKey` **must** implement `init(from decoder:)` manually, using `decodeIfPresent(...) ?? default` for every non-identity field.

Synthesized `Codable` is banned for persisted types.

## Why

Swift's synthesized decoder is strict. If a struct has a field declared that isn't in the JSON being decoded, it throws `DecodingError.keyNotFound`. Our `SharedKey.load` implementations **catch the throw and silently fall back to the default value** (usually `[]` or `.empty`). The cascade:

1. You add a new field to a persisted type in commit N.
2. User relaunches after installing commit N.
3. Their old JSON file (written by commit N-1) doesn't have that field.
4. Decode throws. Fallback returns empty.
5. **The user's entire saved state disappears with no warning log visible in the UI.**

This has happened once (commit `d802801`, which added `lastKnownBusy` to `AgentSession` — two sessions disappeared on the next launch). The manual `init(from decoder:)` pattern makes it impossible to hit again without a deliberate regression.

## The pattern

```swift
nonisolated struct MyPersistedType: Codable, Hashable, Sendable {
  // Required: identity. Decoded strictly; missing → whole record is trash.
  let id: UUID

  // Optional: content with a sensible default.
  var name: String
  var newField: Bool

  init(id: UUID = UUID(), name: String = "", newField: Bool = false) {
    self.id = id
    self.name = name
    self.newField = newField
  }

  // Forward-compatible Codable. ADD NEW FIELDS HERE.
  enum CodingKeys: String, CodingKey {
    case id, name, newField
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(UUID.self, forKey: .id)                              // required
    name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""         // defaulted
    newField = try c.decodeIfPresent(Bool.self, forKey: .newField) ?? false // defaulted
  }
}
```

Required vs optional:

- **Required** — genuinely identity-critical. If this is missing, the record is corrupted and should fail to decode. Usually just `id`.
- **Defaulted with `decodeIfPresent`** — everything else. Pick a safe default. Err strongly on the side of "defaulted" — old JSON files shouldn't wipe data because of cosmetic new fields.

## Checklist when you add a field

1. Add the `var` to the struct.
2. Add a parameter (with default) to the memberwise init.
3. Add the key to `CodingKeys`.
4. Add a `try c.decodeIfPresent(T.self, forKey: .newKey) ?? defaultValue` line in `init(from decoder:)`.
5. **Do NOT** accept a compiler prompt that suggests removing the manual init.

No migration code is needed — old files gain the default on first load, and next save writes the full schema.

## When does `encode(to:)` need the same treatment?

No. Synthesized `encode(to:)` is fine because it writes every declared field. The problem is strictly on the decode path for files that predate a schema change.

## Covered types (as of this doc)

Files following this pattern:

- `supacode/Supacool/Domain/AgentSession.swift` → persisted in `~/.supacode/agent-sessions.json`
- `supacode/Supacool/Features/Board/Persistence/BoardFiltersKey.swift` (type `BoardFilters`) → `~/.supacode/board-filters.json`

If you add another `@Shared`-backed Codable, append it here.

## Why we share `~/.supacode/` with stock supacode

Supacode's `SupacodePaths.baseDirectory` is hardcoded to `~/.supacode/`. Supacool inherits it. In theory, running both apps side-by-side would clobber each other's data. In practice: Supacool has a different bundle ID (`app.morethan.supacool`) so macOS treats them as separate apps, but they read/write the same JSON files.

For a personal fork with one user this is fine — you're not going to have stock supacode AND Supacool registered on the same machine fighting over the same `~/.supacode/layouts.json`. If that ever becomes a problem, add a `SupacoolPaths` helper pointing to `~/.supacool/` and migrate the Supacool-specific files there; leave supacode-owned files (layouts, settings, repos) where they are.

## Why the code comment points here

Both `AgentSession.swift` and `BoardFiltersKey.swift` carry comments saying "convention documented in `Supacool/docs/persistence-convention.md`." That file was moved here (`docs/agent-guides/persistence.md`) as part of the agent-guide restructure; update the code comments to match if you touch them.
