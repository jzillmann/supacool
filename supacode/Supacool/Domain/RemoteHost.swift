import Foundation

/// A remote machine Supacool knows how to SSH into. Either auto-imported
/// from `~/.ssh/config` (then `importSource == .sshConfig`), pulled from
/// shell history (`.shellHistory`), or added by hand (`.manual`).
///
/// Historically Supacool deferred every connection detail (User, Hostname,
/// Port, IdentityFile) to OpenSSH at runtime — the Mac invoked
/// `ssh <sshAlias>` and let `~/.ssh/config` take care of the rest. That
/// model is still available via `deferToSSHConfig`, but the default is
/// now to store connection fields in `connection` and assemble the ssh
/// command ourselves. That unlocks:
///
/// - importing hosts that exist only in shell history (no ssh_config entry);
/// - editing User/Hostname/Port/IdentityFile in Settings without lying
///   about whether runtime actually consults those edits;
/// - a stable snapshot of what Supacool sees, independent of ssh_config
///   edits that happen after import.
///
/// See `docs/agent-guides/remote-hosts.md` for the design rationale and
/// the "bootstrap sources" contract.
nonisolated struct RemoteHost: Identifiable, Hashable, Codable, Sendable {
  let id: UUID
  /// Human-readable label shown in pickers. Defaults to `sshAlias`.
  var alias: String
  /// The `Host` key in ssh_config (or the bare hostname for manual /
  /// history-sourced entries). Used when `deferToSSHConfig == true` or
  /// as the fallback hostname when `connection.hostname == nil`.
  let sshAlias: String
  /// Connection fields Supacool assembles into the ssh command. Populated
  /// at import time from `ssh -G` (for .sshConfig) or parsed flags (for
  /// .shellHistory). Empty entries fall through to OpenSSH's own defaults.
  var connection: Connection
  var overrides: Overrides
  /// Which bootstrap source produced this row. Also feeds the Settings UI
  /// so imported-from-history rows can render a distinct badge.
  var importSource: ImportSource
  /// Stamp of the last time `connection` was populated from ssh_config.
  /// Only set for `.sshConfig` rows; the drift detector compares this
  /// against fresh `ssh -G` output on explicit reload.
  var importedAt: Date?
  /// When `true`, runtime falls back to the old "let OpenSSH resolve it"
  /// model: we invoke `ssh <sshAlias>` with no -p / -i / user@host flags.
  /// Auto-enabled for imports whose `ssh -G` output contains ProxyJump /
  /// Match / token-expansion directives we can't faithfully re-express
  /// from flat `connection` fields.
  var deferToSSHConfig: Bool

  /// Convenience: whether this host came from `~/.ssh/config`. Preserved
  /// as a computed property so existing call sites don't churn.
  var importedFromSSHConfig: Bool { importSource == .sshConfig }

  nonisolated enum ImportSource: String, Codable, Sendable, Hashable {
    /// Added manually via the Settings "Manual host" row.
    case manual
    /// Auto-imported from `~/.ssh/config`.
    case sshConfig
    /// Imported from a `~/.zsh_history` / `~/.bash_history` scan.
    case shellHistory
  }

  nonisolated struct Connection: Hashable, Codable, Sendable {
    /// Remote user. `nil` means "let OpenSSH defaults pick it up"
    /// (typically `$USER`).
    var user: String?
    /// Explicit hostname. `nil` means "use `sshAlias` as the hostname" —
    /// correct for manual entries where the user typed a resolvable name
    /// (`jack.local`) as the alias.
    var hostname: String?
    var port: Int?
    /// Stored literally (`~/.ssh/id_ed25519`). Tilde-expanded by the
    /// spawn path at command-build time, never at import time.
    var identityFile: String?

    init(
      user: String? = nil,
      hostname: String? = nil,
      port: Int? = nil,
      identityFile: String? = nil
    ) {
      self.user = user
      self.hostname = hostname
      self.port = port
      self.identityFile = identityFile
    }

    /// The value assembled into `[user@]hostname` at command-build time.
    /// Falls back to `sshAlias` when `hostname` is unset.
    func effectiveTarget(sshAlias: String) -> String {
      let host = hostname ?? sshAlias
      if let user, !user.isEmpty { return "\(user)@\(host)" }
      return host
    }

    /// True when neither side stored anything — used to suppress
    /// "edited by you" styling on fresh imports.
    var isEmpty: Bool {
      user == nil && hostname == nil && port == nil && identityFile == nil
    }

    // Forward-compatible Codable — see docs/agent-guides/persistence.md.
    enum CodingKeys: String, CodingKey {
      case user, hostname, port, identityFile
    }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      user = try c.decodeIfPresent(String.self, forKey: .user)
      hostname = try c.decodeIfPresent(String.self, forKey: .hostname)
      port = try c.decodeIfPresent(Int.self, forKey: .port)
      identityFile = try c.decodeIfPresent(String.self, forKey: .identityFile)
    }
  }

  nonisolated struct Overrides: Hashable, Codable, Sendable {
    /// Directory on the remote host where Supacool drops temp files
    /// (screenshot uploads, bootstrap scripts). Defaults to `/tmp`.
    var remoteTmpdir: String?
    /// Default path shown in the "new remote workspace" prompt.
    var defaultRemoteWorkspaceRoot: String?
    var notes: String?

    init(
      remoteTmpdir: String? = nil,
      defaultRemoteWorkspaceRoot: String? = nil,
      notes: String? = nil
    ) {
      self.remoteTmpdir = remoteTmpdir
      self.defaultRemoteWorkspaceRoot = defaultRemoteWorkspaceRoot
      self.notes = notes
    }

    /// Convenience: the tmpdir to use, falling back to `/tmp`.
    var effectiveRemoteTmpdir: String { remoteTmpdir ?? "/tmp" }

    // Forward-compatible Codable — see docs/agent-guides/persistence.md.
    enum CodingKeys: String, CodingKey {
      case remoteTmpdir, defaultRemoteWorkspaceRoot, notes
    }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      remoteTmpdir = try c.decodeIfPresent(String.self, forKey: .remoteTmpdir)
      defaultRemoteWorkspaceRoot =
        try c.decodeIfPresent(String.self, forKey: .defaultRemoteWorkspaceRoot)
      notes = try c.decodeIfPresent(String.self, forKey: .notes)
    }
  }

  init(
    id: UUID = UUID(),
    alias: String? = nil,
    sshAlias: String,
    connection: Connection = Connection(),
    overrides: Overrides = Overrides(),
    importSource: ImportSource = .manual,
    importedAt: Date? = nil,
    deferToSSHConfig: Bool = false
  ) {
    self.id = id
    self.alias = alias ?? sshAlias
    self.sshAlias = sshAlias
    self.connection = connection
    self.overrides = overrides
    self.importSource = importSource
    self.importedAt = importedAt
    self.deferToSSHConfig = deferToSSHConfig
  }

  /// Convenience kept for back-compat with existing call sites and tests
  /// that pre-date `importSource`. Maps `importedFromSSHConfig: true` to
  /// `.sshConfig`, `false` to `.manual`; sets `deferToSSHConfig = true`
  /// when the legacy flag is set, since those rows had no stored
  /// `connection` and must defer at runtime.
  init(
    id: UUID = UUID(),
    alias: String? = nil,
    sshAlias: String,
    importedFromSSHConfig: Bool,
    overrides: Overrides = Overrides()
  ) {
    self.init(
      id: id,
      alias: alias,
      sshAlias: sshAlias,
      connection: Connection(),
      overrides: overrides,
      importSource: importedFromSSHConfig ? .sshConfig : .manual,
      importedAt: nil,
      deferToSSHConfig: importedFromSSHConfig
    )
  }

  // Forward-compatible Codable — see docs/agent-guides/persistence.md.
  // `importSource` migrates from the legacy `importedFromSSHConfig` bool
  // when the new key is missing. `deferToSSHConfig` migrates to `true`
  // for legacy ssh-config rows so existing spawns keep working until the
  // user hits "Reload" to populate `connection`.
  enum CodingKeys: String, CodingKey {
    case id, alias, sshAlias, connection, overrides
    case importSource, importedAt, deferToSSHConfig
    case importedFromSSHConfig
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(UUID.self, forKey: .id)
    sshAlias = try c.decode(String.self, forKey: .sshAlias)
    alias = try c.decodeIfPresent(String.self, forKey: .alias) ?? sshAlias
    connection =
      try c.decodeIfPresent(Connection.self, forKey: .connection) ?? Connection()
    overrides = try c.decodeIfPresent(Overrides.self, forKey: .overrides) ?? Overrides()

    if let explicitSource = try c.decodeIfPresent(ImportSource.self, forKey: .importSource) {
      importSource = explicitSource
    } else if try c.decodeIfPresent(Bool.self, forKey: .importedFromSSHConfig) == true {
      importSource = .sshConfig
    } else {
      importSource = .manual
    }

    importedAt = try c.decodeIfPresent(Date.self, forKey: .importedAt)

    if let explicitDefer = try c.decodeIfPresent(Bool.self, forKey: .deferToSSHConfig) {
      deferToSSHConfig = explicitDefer
    } else {
      // Legacy ssh-config rows had no `connection` stored; runtime must
      // defer until the user reloads and populates real fields.
      deferToSSHConfig = (importSource == .sshConfig)
    }
  }

  /// Encodes both `importSource` and the legacy `importedFromSSHConfig`
  /// so an older build reading the same JSON still renders the source
  /// badge correctly. Remove once we no longer care about downgrade
  /// compat.
  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(alias, forKey: .alias)
    try c.encode(sshAlias, forKey: .sshAlias)
    try c.encode(connection, forKey: .connection)
    try c.encode(overrides, forKey: .overrides)
    try c.encode(importSource, forKey: .importSource)
    try c.encodeIfPresent(importedAt, forKey: .importedAt)
    try c.encode(deferToSSHConfig, forKey: .deferToSSHConfig)
    try c.encode(importedFromSSHConfig, forKey: .importedFromSSHConfig)
  }
}
