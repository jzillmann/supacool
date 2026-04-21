import Foundation

/// A remote machine Supacool knows how to SSH into. Either auto-imported
/// from `~/.ssh/config` (then `importedFromSSHConfig == true`) or added
/// manually. Supacool never re-expresses Hostname/User/Port/IdentityFile —
/// it invokes `ssh <sshAlias>` and lets OpenSSH resolve them.
///
/// `overrides` carries Supacool-specific knobs that don't belong in
/// `ssh_config`: where to drop temp files on the remote, a default
/// workspace root, operator notes.
nonisolated struct RemoteHost: Identifiable, Hashable, Codable, Sendable {
  let id: UUID
  /// Human-readable label shown in pickers. Defaults to `sshAlias`.
  var alias: String
  /// The `Host` key in ssh_config; what we pass to `ssh` on the command line.
  let sshAlias: String
  /// Whether this host was seeded from `~/.ssh/config`. Used to render a
  /// source badge in the Settings panel and to decide whether an ssh-config
  /// reload can safely forget this entry.
  var importedFromSSHConfig: Bool
  var overrides: Overrides

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
    importedFromSSHConfig: Bool = false,
    overrides: Overrides = Overrides()
  ) {
    self.id = id
    self.alias = alias ?? sshAlias
    self.sshAlias = sshAlias
    self.importedFromSSHConfig = importedFromSSHConfig
    self.overrides = overrides
  }

  // Forward-compatible Codable — see docs/agent-guides/persistence.md.
  enum CodingKeys: String, CodingKey {
    case id, alias, sshAlias, importedFromSSHConfig, overrides
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(UUID.self, forKey: .id)
    sshAlias = try c.decode(String.self, forKey: .sshAlias)
    alias = try c.decodeIfPresent(String.self, forKey: .alias) ?? sshAlias
    importedFromSSHConfig =
      try c.decodeIfPresent(Bool.self, forKey: .importedFromSSHConfig) ?? false
    overrides = try c.decodeIfPresent(Overrides.self, forKey: .overrides) ?? Overrides()
  }
}
