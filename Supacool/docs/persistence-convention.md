# Persistence convention: forward-compatible Codable

**Rule**: every Supacool type that gets persisted via `@Shared` / `SharedKey`
must implement its `init(from decoder:)` manually, using
`decodeIfPresent(...) ?? default` for every non-critical field.

## Why

Swift's synthesized `Codable` decoder is strict: if a field is declared on
the struct but missing from the JSON being decoded, it throws
`DecodingError.keyNotFound`. Our `SharedKey` load paths catch the throw and
silently fall back to the default value (usually empty). The result:

- You add a new field to a persisted type in commit N.
- User relaunches after installing commit N.
- Their old JSON file (written by commit N-1) doesn't have that field.
- Decode throws, fallback kicks in, **the user's entire saved state
  disappears**.

This happened once (see commit `d802801` — adding `lastKnownBusy` to
`AgentSession` made `tell me a joke` and `find a bug` vanish after a
restart). It's a landmine that fires on every schema change if the author
isn't thinking about migration.

Manual `init(from decoder:)` with `decodeIfPresent` defeats it: missing
fields decode to their safe default, the rest of the struct decodes
normally, and no data is lost.

## Pattern

```swift
nonisolated struct MyPersistedType: Codable {
  let id: UUID
  var name: String
  var newField: Bool

  // Public memberwise init stays as-is.
  init(id: UUID = UUID(), name: String, newField: Bool = false) {
    self.id = id
    self.name = name
    self.newField = newField
  }

  // Forward-compatible Codable. Keep this init when adding new fields;
  // just append `decodeIfPresent ?? default` lines.
  enum CodingKeys: String, CodingKey {
    case id, name, newField
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(UUID.self, forKey: .id)                              // required
    name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""         // optional
    newField = try c.decodeIfPresent(Bool.self, forKey: .newField) ?? false // optional
  }
}
```

## When a field is "required" vs "optional"

- **Required** (decode, no default): truly essential to the struct's
  identity or correctness. Usually the `id` and any immutable
  identity-defining fields. If these are missing, the file really is
  corrupted and falling back to empty is the right call.
- **Optional** (decodeIfPresent with default): everything else. If a sane
  default exists, use `decodeIfPresent`. Err strongly on the side of
  "optional" — it's almost always the right choice for persisted data.

## Checklist when adding a field to a persisted type

1. Add the field to the `struct`.
2. Add it to the memberwise `init` with a default.
3. Add it to `CodingKeys`.
4. Add a `decodeIfPresent ?? default` line in `init(from decoder:)`.
5. No migration code required — old files automatically gain the default.

## Covered types (as of this doc)

Persisted Supacool types that follow this pattern:

- `supacode/Supacool/Domain/AgentSession.swift` — sessions list
  (`~/.supacode/agent-sessions.json`).
- `supacode/Supacool/Features/Board/Persistence/BoardFiltersKey.swift`
  → `BoardFilters` struct (`~/.supacode/board-filters.json`).

`AgentType` is a String-raw-value enum and doesn't need the pattern
(the raw value is the whole payload; forward-compat is inherent).

If you add a new `@Shared` key backed by a Codable struct, follow this
convention and add the type to the list above.
