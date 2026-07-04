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

- `Supacool/Domain/AgentSession.swift` → persisted per session in `~/.supacool/sessions/<uuid>/session.json` (see below)
- `Supacool/Domain/SessionTerminal.swift` → embedded inside each `AgentSession.terminals[]`
- `Supacool/Domain/Bookmark.swift` (via `BookmarksKey`) → `~/.supacool/bookmarks.json`
- `Supacool/Domain/Draft.swift` (via `DraftsKey`) → `~/.supacool/drafts.json`
- `Supacool/Domain/TrashedSession.swift` (via `TrashedSessionsKey`) → `~/.supacool/trashed-sessions.json`
- `Supacool/Domain/LinearTicket.swift` (via `LinearInboxKey`) → `~/.supacool/linear-inbox.json`
- `Supacool/Domain/RemoteHost.swift` (via `RemoteHostsKey`) → `~/.supacool/remote-hosts.json`
- `Supacool/Features/RemoteHosts/Persistence/RemoteWorkspacesKey.swift` (type `RemoteWorkspace`) → `~/.supacool/remote-workspaces.json`
- `Supacool/Features/Board/Persistence/BoardFiltersKey.swift` (type `BoardFilters`) → `~/.supacool/board-filters.json`
- `supacode/Features/Settings/Models/SettingsFile.swift` (type `SettingsFile`) → `~/.supacool/settings.json`
- `supacode/Features/Settings/Models/GlobalSettings.swift` (type `GlobalSettings`) → embedded in `settings.json`
- `supacode/Features/Settings/Models/RepositorySettings.swift` (types `RepositorySettings` and
  `ServerLifecycleSettings`) → embedded in `settings.json` and per-repo `supacool.json`
- `supacode/Features/Terminal/Models/TerminalLayoutSnapshot.swift` (types `TerminalLayoutSnapshot` and `TabSnapshot`) → `~/.supacool/layouts.json`

If you add another `@Shared`-backed Codable, append it here.

### Special case: sessions live in a directory store, not one JSON file

`AgentSession` storage moved from a single `agent-sessions.json` array to a **per-session directory store**: `~/.supacool/sessions/<session-uuid>/session.json`, managed by `SessionDirectoryStore` behind `AgentSessionsKey`. Load scans the directory (an undecodable file is skipped, never fatal); save is coalesced off the main thread and writes only changed session files, atomically. Sessions removed from the array are journaled to `~/.supacool/agent-sessions-recovery.json` (`SessionRecoveryStore`) *before* their folder is deleted. The forward-compat decoding rules on this page apply unchanged to each `session.json`.

Two consequences for you:
1. Don't use `AgentSessionsKey` as the template for a new persisted key — copy one of the simple one-file keys (`BookmarksKey`, `DraftsKey`) instead.
2. Board tests **must** use the `.dependencies` Swift Testing trait so `sessionStorageLocations` resolves a per-test temp directory; otherwise tests share one `@Shared` box (and the real `~/.supacool/sessions`) and pollute each other. See the doc comment on `AgentSessionsKey.swift`.

### Special case: schema-shape migrations

`AgentSession` itself did a one-time schema reshape: the per-terminal fields
(`agent`, `initialPrompt`, `agentNativeSessionID`, `lastKnownBusy`,
`hasObservedInitialAgentEvent`, `hasCompletedAtLeastOnce`,
`lastActivityAt`, `lastBusyTransitionAt`) moved into a new
`terminals: [SessionTerminal]` array with `primaryTerminalID: UUID`.
`init(from decoder:)` detects an absent `terminals` key and synthesizes a
single primary terminal from the legacy top-level keys. Old files thus
upgrade in place; new writes drop the legacy keys. The legacy keys remain
in `CodingKeys` solely so the read path can find them — do not delete.

## On-disk location

All app data lives under `~/.supacool/` via `SupacoolPaths.baseDirectory`. Stock upstream supacode uses `~/.supacode/`; the two are cleanly separate now, so both apps can coexist without clobbering each other's files. An older Supacool install (pre-rename) kept data in `~/.supacode/`; the one-time migration is documented in `RELEASING.md`.

## Why the code comment points here

Both `AgentSession.swift` and `BoardFiltersKey.swift` carry comments saying "convention documented in `Supacool/docs/persistence-convention.md`." That file was moved here (`docs/agent-guides/persistence.md`) as part of the agent-guide restructure; update the code comments to match if you touch them.
