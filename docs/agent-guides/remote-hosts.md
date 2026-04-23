# Remote hosts: model & bootstrap sources

Supacool's remote-terminal feature (`supacode/Supacool/Features/RemoteHosts/`, `supacode/Supacool/Domain/RemoteHost.swift`) needs to know how to SSH into a host. This doc captures the model and — more importantly — **why the model stores connection fields itself instead of deferring to `~/.ssh/config` at runtime**.

> Read this before touching `RemoteHost`, `SSHConfigClient`, `RemoteSpawnClient`, or the Remote Hosts settings panel. There is a prior design (reflected in the git history up to early commits on the `supacool` branch) that *did* defer to OpenSSH; we walked away from it for the reasons below.

---

## The model

```swift
RemoteHost
  id, alias, sshAlias
  connection: Connection           // user / hostname / port / identityFile
  overrides: Overrides             // tmpdir / workspaceRoot / notes
  importSource: .sshConfig | .shellHistory | .manual
  importedAt: Date?                // for "ssh_config changed since import" hints
  deferToSSHConfig: Bool           // escape hatch for complex ssh_config setups
```

`Connection` holds the four fields OpenSSH itself consults — `user`, `hostname`, `port`, `identityFile` — as `String?` / `Int?`. Empty means "don't pass `-o` flag for this, let OpenSSH defaults kick in."

`Overrides` is unchanged from the original design: `remoteTmpdir`, `defaultRemoteWorkspaceRoot`, `notes`. These have no equivalent in `ssh_config`; they're Supacool-only.

`deferToSSHConfig = true` collapses runtime behaviour back to the old model: Supacool runs `ssh <sshAlias>` and lets OpenSSH resolve everything. Used for hosts where `ssh_config` declares `ProxyJump`, `Match host …`, `Include`, token expansion (`%h`, `%r`), or other directives Supacool doesn't model. Default `false` on manual / shell-history imports, auto-set to `true` on ssh_config imports whose `ssh -G` output contains non-flat directives.

## Why store connection fields instead of deferring

Short version: **the cost of re-expressing four fields is low; the cost of "let OpenSSH resolve it" locks us out of the shell-history use case and makes the Settings UI dishonest.**

1. **Shell-history hosts have no ssh_config entry.** If the user has been typing `ssh jz@jack.local` directly for months, there's nothing in `ssh_config` for Supacool to import. Either we write into their ssh_config (invasive; needs an `Include` dance to stay tidy) or we store the fields ourselves. The second is simpler and doesn't touch the user's hand-maintained config.
2. **Editing in Settings becomes real.** Under the deferred model, the Remote Hosts settings panel could only show Supacool-only overrides (tmpdir, workspace root, notes) — any attempt to edit User/Hostname/Port would be a lie because runtime ignored those fields. Storing them makes the four inputs you'd expect to see actually editable.
3. **Single source of truth for what Supacool sees.** `ssh_config` can be edited, `Include`d, templated, and network-mounted; a Supacool copy is stable once imported. Users who *want* live ssh_config resolution opt in via the escape-hatch toggle.

The deferred model's one real advantage — ssh_config directives like `ProxyJump` work for free — is preserved via `deferToSSHConfig`.

## Bootstrap sources

Both sources populate the same fields; only `importSource` and any "hint" badges differ.

### `~/.ssh/config` (via `ssh -G`)

`SSHConfigClient.effectiveConfig(alias:)` shells `ssh -G <alias>` and parses the key/value output. That already runs; today only `SSHConfigClient.listAliases()` is consumed by the reducer. Extend `RemoteHostsFeature._aliasesLoaded` to call `effectiveConfig` per new alias and seed `RemoteHost.connection` from it.

`ssh -G` is authoritative over `Include`, `Match`, wildcards, and token expansion — we don't re-parse ssh_config ourselves. If the emitted config contains directives we can't flatten safely (`proxyjump`, `proxycommand`, certificate files, or `%`-tokens surviving expansion, which can happen for `Match` blocks), mark the row `deferToSSHConfig = true` so runtime falls back to `ssh <alias>` and we don't lie about what we stored.

### Shell history

New client `SSHHistoryClient`:

```swift
listCandidates() async throws -> [SSHHistoryCandidate]

struct SSHHistoryCandidate {
  let raw: String          // original command line
  let user: String?
  let hostname: String
  let port: Int?
  let identityFile: String?
  let timesSeen: Int
  let lastSeenAt: Date?
}
```

Parses `~/.zsh_history` (extended format `: <timestamp>:<elapsed>;<command>`) and `~/.bash_history`. Regex: `\bssh\b(?:\s+-[^-\s]\S*|\s+-o\s+\S+)*\s+(?:([a-zA-Z0-9._-]+)@)?([a-zA-Z0-9.-]+)` plus targeted `-p <port>` and `-i <path>` extraction. Ignore lines inside `if/for/while` blocks of `.zshrc` snippets if found; only use `_history` files, not rc files. Dedupe by `(user, hostname, port, identityFile)`.

UI surface: in `RemoteHostsSettingsView`, a disclosure section "Found in shell history" lists candidates with checkboxes (default on for ones not already imported). A single **Import selected** button bulk-creates `RemoteHost` rows with `importSource = .shellHistory`. Already-present `(user, hostname, port)` combinations are filtered out.

## Runtime command assembly

`RemoteSpawnClient.sshInvocation(for:host:…)` (see `docs/agent-guides/architecture.md` and the PR 2 plan) builds:

```text
/usr/bin/ssh -tt \
  -o ControlMaster=auto -o ControlPath=… -o ControlPersist=600 \
  -o StreamLocalBindUnlink=yes \
  -R <remoteSock>:<localSock> \
  -o SetEnv=… \
  [-p <port>] [-i <identityFile>] \
  [<user>@]<hostname> \
  '~/.supacool/bootstrap-<sha>.sh'
```

When `deferToSSHConfig == true`, the `[-p …] [-i …] [<user>@]<hostname>` block is replaced by `<sshAlias>` and nothing else — OpenSSH resolves the rest. `SetEnv`, `ControlMaster`, and the reverse-forward flag are common to both paths.

`identityFile` is stored as written (`~/.ssh/id_ed25519`); tilde-expand at command-build time, never at import time.

## Drift handling

`importedAt` gets stamped on every successful import. The Remote Hosts settings panel does not auto-reimport — the user clicks **Reload from ~/.ssh/config**, which:

1. Calls `ssh -G` for every host with `importSource == .sshConfig`.
2. Diffs each field; if different, marks the row with a `⚠ ssh_config changed since import` hint and offers **Re-import** per-row or **Re-import all**.

No silent overwrite. Supacool's stored state is treated as user-owned from the moment of first import.

## What *not* to add

- **Writing into `~/.ssh/config`.** Considered, rejected. Users' ssh_configs are load-bearing for other tools (`rsync`, `mosh`, VS Code Remote); accidental writes are a support burden. The shell-history path specifically exists so users can onboard *without* editing ssh_config.
- **Full ssh_config semantics in Swift.** `ssh -G` is the delegate. If we need a field, we read it from `ssh -G` output, not from the raw file.
- **Auto-sync on reload.** Explicit Re-import, not background rewrite. Users who edit ssh_config have a reason; don't clobber.

---

## Pointers into the code

| Concern | File |
|---|---|
| Persisted shape | `supacode/Supacool/Domain/RemoteHost.swift` |
| Persistence key + forward-compat Codable | `supacode/Supacool/Features/RemoteHosts/Persistence/RemoteHostsKey.swift` |
| Reducer (import + CRUD) | `supacode/Supacool/Features/RemoteHosts/Reducer/RemoteHostsFeature.swift` |
| ssh_config client (`ssh -G`) | `supacode/Supacool/Clients/SSHConfigClient.swift` |
| Settings UI | `supacode/Supacool/Features/Settings/Views/RemoteHostsSettingsView.swift` |
| Spawn command assembly (future) | `supacode/Supacool/Clients/RemoteSpawnClient.swift` |

Related: `docs/agent-guides/persistence.md` (how to add new fields safely), `docs/agent-guides/architecture.md` (where this fits in the overall TCA graph).
