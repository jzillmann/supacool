import Foundation
import Testing

@testable import Supacool

/// Verifies the forward-compatible Codable contract for `RemoteHost` and
/// `RemoteWorkspace` — the same "missing fields decode to defaults" rule
/// that `AgentSession` lives by. Without these tests, adding a new field
/// later risks silently wiping persisted data on read failure.
struct RemoteHostPersistenceTests {

  // MARK: RemoteHost

  @Test func remoteHostRoundTripsThroughJSON() throws {
    let stamp = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
    let host = RemoteHost(
      alias: "Dev Box",
      sshAlias: "dev",
      connection: RemoteHost.Connection(
        user: "jz",
        hostname: "dev.example.com",
        port: 2222,
        identityFile: "~/.ssh/id_ed25519"
      ),
      overrides: RemoteHost.Overrides(
        remoteTmpdir: "/home/jz/.tmp",
        defaultRemoteWorkspaceRoot: "/home/jz/code",
        notes: "home office"
      ),
      importSource: .sshConfig,
      importedAt: stamp,
      deferToSSHConfig: false
    )

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let data = try encoder.encode(host)
    let decoded = try decoder.decode(RemoteHost.self, from: data)

    #expect(decoded == host)
  }

  @Test func remoteHostDecodesLegacyJSONWithoutOverrides() throws {
    // Simulates a file written by an older build that had no overrides,
    // no connection fields, and only the legacy `importedFromSSHConfig`.
    // Must migrate cleanly: importSource → .sshConfig, deferToSSHConfig
    // → true (we had no stored connection to spawn with).
    let json = """
      {
        "id": "\(UUID().uuidString)",
        "alias": "Dev Box",
        "sshAlias": "dev",
        "importedFromSSHConfig": true
      }
      """
    let decoded = try JSONDecoder().decode(RemoteHost.self, from: Data(json.utf8))
    #expect(decoded.overrides.remoteTmpdir == nil)
    #expect(decoded.overrides.effectiveRemoteTmpdir == "/tmp")
    #expect(decoded.connection.isEmpty)
    #expect(decoded.importSource == .sshConfig)
    #expect(decoded.deferToSSHConfig == true)
  }

  @Test func remoteHostDecodesLegacyManualRowWithoutImportSource() throws {
    let id = UUID()
    let json = """
      {
        "id": "\(id.uuidString)",
        "sshAlias": "devbox",
        "importedFromSSHConfig": false
      }
      """
    let decoded = try JSONDecoder().decode(RemoteHost.self, from: Data(json.utf8))
    #expect(decoded.importSource == .manual)
    #expect(decoded.deferToSSHConfig == false)
  }

  @Test func remoteHostDecodesBareJSONWithOnlyRequiredFields() throws {
    let id = UUID()
    let json = """
      { "id": "\(id.uuidString)", "sshAlias": "prod" }
      """
    let decoded = try JSONDecoder().decode(RemoteHost.self, from: Data(json.utf8))
    #expect(decoded.id == id)
    #expect(decoded.alias == "prod")  // falls back to sshAlias
    #expect(decoded.importSource == .manual)
    #expect(decoded.importedFromSSHConfig == false)
    #expect(decoded.deferToSSHConfig == false)
    #expect(decoded.connection.isEmpty)
  }

  @Test func remoteHostConnectionDefaults() throws {
    let connection = RemoteHost.Connection()
    #expect(connection.isEmpty)
    #expect(connection.effectiveTarget(sshAlias: "jack.local") == "jack.local")
  }

  @Test func remoteHostConnectionPrependsUser() throws {
    let connection = RemoteHost.Connection(user: "jz")
    #expect(connection.effectiveTarget(sshAlias: "jack.local") == "jz@jack.local")
  }

  @Test func remoteHostConnectionUsesExplicitHostname() throws {
    let connection = RemoteHost.Connection(user: "jz", hostname: "10.0.0.2")
    #expect(connection.effectiveTarget(sshAlias: "jack.local") == "jz@10.0.0.2")
  }

  @Test func remoteHostEncodesBothLegacyAndNewFields() throws {
    // Downgrade-compat: an older Supacool reading this JSON must still
    // see `importedFromSSHConfig` so it renders the source badge.
    let host = RemoteHost(
      sshAlias: "dev",
      importSource: .sshConfig,
      deferToSSHConfig: false
    )
    let data = try JSONEncoder().encode(host)
    let json = try #require(
      try JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    #expect(json["importSource"] as? String == "sshConfig")
    #expect(json["importedFromSSHConfig"] as? Bool == true)
    #expect(json["deferToSSHConfig"] as? Bool == false)
  }

  @Test func remoteHostOverridesIndividualMissingFields() throws {
    // Encode a partial overrides blob to verify each decodeIfPresent line.
    let json = """
      { "remoteTmpdir": "/var/tmp" }
      """
    let decoded = try JSONDecoder().decode(RemoteHost.Overrides.self, from: Data(json.utf8))
    #expect(decoded.remoteTmpdir == "/var/tmp")
    #expect(decoded.defaultRemoteWorkspaceRoot == nil)
    #expect(decoded.notes == nil)
  }

  // MARK: RemoteWorkspace

  @Test func remoteWorkspaceRoundTrips() throws {
    // Clamp to whole seconds — .iso8601 strategy drops sub-second precision
    // on encode, so a naïve Date() round-trip diverges by fractional ms.
    let whenSeconds = floor(Date().timeIntervalSince1970)
    let ws = RemoteWorkspace(
      hostID: UUID(),
      remoteWorkingDirectory: "/home/jz/code/backend",
      displayName: "Backend",
      createdAt: Date(timeIntervalSince1970: whenSeconds)
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let data = try encoder.encode(ws)
    let decoded = try decoder.decode(RemoteWorkspace.self, from: data)
    #expect(decoded == ws)
  }

  @Test func remoteWorkspaceDerivesDisplayNameFromPath() {
    let derived = RemoteWorkspace.deriveDisplayName(from: "/home/jz/code/backend")
    #expect(derived == "backend")

    let trailingSlash = RemoteWorkspace.deriveDisplayName(from: "/home/jz/code/backend/")
    #expect(trailingSlash == "backend")

    let noSlash = RemoteWorkspace.deriveDisplayName(from: "scratch")
    #expect(noSlash == "scratch")
  }

  @Test func remoteWorkspaceDecodesLegacyJSONWithoutDisplayName() throws {
    let id = UUID()
    let hostID = UUID()
    let json = """
      {
        "id": "\(id.uuidString)",
        "hostID": "\(hostID.uuidString)",
        "remoteWorkingDirectory": "/srv/app"
      }
      """
    let decoded = try JSONDecoder().decode(RemoteWorkspace.self, from: Data(json.utf8))
    #expect(decoded.id == id)
    #expect(decoded.hostID == hostID)
    #expect(decoded.displayName == "app")
  }

  // MARK: AgentSession remote fields

  @Test func agentSessionRoundTripsRemoteFields() throws {
    let workspaceID = UUID()
    let hostID = UUID()
    let session = AgentSession(
      repositoryID: "remote:dev:/home/jz/code/app",
      worktreeID: "remote:dev:/home/jz/code/app",
      agent: .claude,
      initialPrompt: "fix the thing",
      remoteWorkspaceID: workspaceID,
      remoteHostID: hostID,
      tmuxSessionName: "supacool-abc123",
      remoteConnectionLost: true
    )

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let data = try encoder.encode(session)
    let decoded = try decoder.decode(AgentSession.self, from: data)

    #expect(decoded.remoteWorkspaceID == workspaceID)
    #expect(decoded.remoteHostID == hostID)
    #expect(decoded.tmuxSessionName == "supacool-abc123")
    #expect(decoded.remoteConnectionLost == true)
    #expect(decoded.isRemote == true)
  }

  @Test func agentSessionDecodesLegacyJSONWithoutRemoteFields() throws {
    // This is the critical test: a sessions.json written BEFORE the
    // three remote fields existed must decode cleanly without wiping
    // the user's board.
    let id = UUID()
    let json = """
      {
        "id": "\(id.uuidString)",
        "repositoryID": "/Users/jz/repo",
        "worktreeID": "/Users/jz/repo",
        "initialPrompt": "hello"
      }
      """
    let decoded = try JSONDecoder().decode(AgentSession.self, from: Data(json.utf8))
    #expect(decoded.id == id)
    #expect(decoded.remoteWorkspaceID == nil)
    #expect(decoded.remoteHostID == nil)
    #expect(decoded.tmuxSessionName == nil)
    #expect(decoded.remoteConnectionLost == false)
    #expect(decoded.isRemote == false)
  }
}
