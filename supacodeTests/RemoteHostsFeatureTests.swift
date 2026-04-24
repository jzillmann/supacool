import ComposableArchitecture
import Foundation
import Testing

@testable import Supacool

/// Covers the import-and-diff behaviour users rely on every time they add
/// or remove a host from `~/.ssh/config`: new aliases show up, existing
/// aliases don't double-insert, explicitly-forgotten aliases stay gone,
/// and override edits survive a reload. Also covers the bootstrap-store
/// model — connection fields come from `ssh -G`, drift is surfaced
/// non-destructively, and re-import is an explicit user action.
@MainActor
struct RemoteHostsFeatureTests {

  private static func sshConfig(
    aliases: [String],
    resolved: [String: EffectiveSSHConfig] = [:],
    failOnResolve: Bool = false
  ) -> SSHConfigClient {
    SSHConfigClient(
      listAliases: { aliases },
      effectiveConfig: { alias in
        if failOnResolve {
          struct Boom: Error {}
          throw Boom()
        }
        if let cfg = resolved[alias] { return cfg }
        // Reasonable default so older tests that only care about
        // `listAliases` aren't blown up by the new fan-out.
        return EffectiveSSHConfig(
          alias: alias,
          hostname: alias,
          user: nil,
          port: nil,
          identityFiles: [],
          hasComplexDirectives: false
        )
      }
    )
  }

  @Test func appearedImportsAliasesOnce() async throws {
    let store = TestStore(initialState: RemoteHostsFeature.State()) {
      RemoteHostsFeature()
    } withDependencies: {
      $0.sshConfigClient = Self.sshConfig(aliases: ["dev", "prod"])
      $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.appeared) { $0.isReloading = true }
    await store.receive(\._aliasesResolved) { $0.isReloading = false }

    #expect(store.state.hosts.count == 2)
    #expect(store.state.hosts.map(\.sshAlias) == ["dev", "prod"])
    #expect(store.state.hosts.allSatisfy { $0.importedFromSSHConfig })
    #expect(store.state.hosts.allSatisfy { $0.importSource == .sshConfig })
    #expect(store.state.hosts.allSatisfy { $0.importedAt != nil })
  }

  @Test func importPopulatesConnectionFromSshMinusG() async throws {
    let resolved: [String: EffectiveSSHConfig] = [
      "dev": EffectiveSSHConfig(
        alias: "dev",
        hostname: "dev.example.com",
        user: "jz",
        port: 2222,
        identityFiles: ["/Users/jz/.ssh/id_ed25519"],
        hasComplexDirectives: false
      ),
    ]
    let store = TestStore(initialState: RemoteHostsFeature.State()) {
      RemoteHostsFeature()
    } withDependencies: {
      $0.sshConfigClient = Self.sshConfig(aliases: ["dev"], resolved: resolved)
      $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.appeared)
    await store.receive(\._aliasesResolved)

    let host = try #require(store.state.hosts.first)
    #expect(host.connection.user == "jz")
    #expect(host.connection.hostname == "dev.example.com")
    #expect(host.connection.port == 2222)
    #expect(host.connection.identityFile == "/Users/jz/.ssh/id_ed25519")
    #expect(host.deferToSSHConfig == false)
  }

  @Test func importAutoDefersWhenSshConfigHasComplexDirectives() async throws {
    let resolved: [String: EffectiveSSHConfig] = [
      "jump": EffectiveSSHConfig(
        alias: "jump",
        hostname: "behind.bastion",
        user: "jz",
        port: nil,
        identityFiles: [],
        hasComplexDirectives: true
      ),
    ]
    let store = TestStore(initialState: RemoteHostsFeature.State()) {
      RemoteHostsFeature()
    } withDependencies: {
      $0.sshConfigClient = Self.sshConfig(aliases: ["jump"], resolved: resolved)
      $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.appeared)
    await store.receive(\._aliasesResolved)

    #expect(store.state.hosts.first?.deferToSSHConfig == true)
  }

  @Test func failedSshMinusGStillImportsAliasWithEmptyConnection() async throws {
    let store = TestStore(initialState: RemoteHostsFeature.State()) {
      RemoteHostsFeature()
    } withDependencies: {
      $0.sshConfigClient = Self.sshConfig(aliases: ["flaky"], failOnResolve: true)
      $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.appeared)
    await store.receive(\._aliasesResolved)

    let host = try #require(store.state.hosts.first)
    #expect(host.sshAlias == "flaky")
    #expect(host.connection.isEmpty)
    // With no resolved info we can't promise flat connection works,
    // so the spawn path must defer.
    #expect(host.deferToSSHConfig == true)
  }

  @Test func reloadDoesNotDuplicateExistingAliases() async throws {
    var state = RemoteHostsFeature.State()
    state.$hosts.withLock {
      $0 = [RemoteHost(sshAlias: "dev", importedFromSSHConfig: true)]
    }
    let store = TestStore(initialState: state) {
      RemoteHostsFeature()
    } withDependencies: {
      $0.sshConfigClient = Self.sshConfig(aliases: ["dev", "prod"])
      $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.reloadFromSSHConfig)
    await store.receive(\._aliasesResolved)

    #expect(store.state.hosts.map(\.sshAlias) == ["dev", "prod"])
  }

  @Test func reloadSkipsForgottenAliases() async throws {
    var state = RemoteHostsFeature.State()
    state.forgottenAliases = ["staging"]
    let store = TestStore(initialState: state) {
      RemoteHostsFeature()
    } withDependencies: {
      $0.sshConfigClient = Self.sshConfig(aliases: ["dev", "staging"])
      $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.reloadFromSSHConfig)
    await store.receive(\._aliasesResolved)

    #expect(store.state.hosts.map(\.sshAlias) == ["dev"])
  }

  @Test func reloadDetectsDriftOnExistingSshConfigRow() async throws {
    let original = RemoteHost(
      sshAlias: "dev",
      connection: RemoteHost.Connection(
        user: "old-user",
        hostname: "old.host",
        port: 22,
        identityFile: nil
      ),
      importSource: .sshConfig,
      importedAt: Date(timeIntervalSince1970: 1_600_000_000),
      deferToSSHConfig: false
    )
    var state = RemoteHostsFeature.State()
    state.$hosts.withLock { $0 = [original] }

    let fresh = EffectiveSSHConfig(
      alias: "dev",
      hostname: "new.host",
      user: "new-user",
      port: 22,
      identityFiles: [],
      hasComplexDirectives: false
    )
    let store = TestStore(initialState: state) {
      RemoteHostsFeature()
    } withDependencies: {
      $0.sshConfigClient = Self.sshConfig(aliases: ["dev"], resolved: ["dev": fresh])
      $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.reloadFromSSHConfig)
    await store.receive(\._aliasesResolved)

    // Stored row untouched.
    #expect(store.state.hosts.first?.connection.user == "old-user")
    // Drift recorded.
    let report = try #require(store.state.drift[original.id])
    #expect(report.userChanged)
    #expect(report.hostnameChanged)
    #expect(!report.portChanged)
  }

  @Test func reimportRowAppliesFreshConfigAndClearsDrift() async throws {
    let original = RemoteHost(
      sshAlias: "dev",
      connection: RemoteHost.Connection(user: "old"),
      importSource: .sshConfig,
      deferToSSHConfig: false
    )
    var state = RemoteHostsFeature.State()
    state.$hosts.withLock { $0 = [original] }
    let fresh = EffectiveSSHConfig(
      alias: "dev",
      hostname: "dev.example.com",
      user: "jz",
      port: 2222,
      identityFiles: ["~/.ssh/id_ed25519"],
      hasComplexDirectives: false
    )
    state.drift[original.id] = RemoteHostsFeature.DriftReport(
      userChanged: true,
      hostnameChanged: true,
      portChanged: true,
      identityFileChanged: true,
      fresh: fresh
    )

    let store = TestStore(initialState: state) {
      RemoteHostsFeature()
    } withDependencies: {
      $0.date = .constant(Date(timeIntervalSince1970: 1_800_000_000))
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.reimportRow(id: original.id))

    let host = try #require(store.state.hosts.first)
    #expect(host.connection.user == "jz")
    #expect(host.connection.hostname == "dev.example.com")
    #expect(host.connection.port == 2222)
    #expect(host.connection.identityFile == "~/.ssh/id_ed25519")
    #expect(store.state.drift[original.id] == nil)
  }

  @Test func updateConnectionClearsDrift() async throws {
    let original = RemoteHost(
      sshAlias: "dev",
      importSource: .sshConfig,
      deferToSSHConfig: false
    )
    var state = RemoteHostsFeature.State()
    state.$hosts.withLock { $0 = [original] }
    state.drift[original.id] = RemoteHostsFeature.DriftReport(
      userChanged: true,
      hostnameChanged: false,
      portChanged: false,
      identityFileChanged: false,
      fresh: EffectiveSSHConfig(
        alias: "dev",
        hostname: "dev",
        user: "someone-else",
        port: nil,
        identityFiles: [],
        hasComplexDirectives: false
      )
    )
    let store = TestStore(initialState: state) {
      RemoteHostsFeature()
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(
      .updateConnection(
        id: original.id,
        connection: RemoteHost.Connection(user: "jz")
      )
    )

    #expect(store.state.hosts.first?.connection.user == "jz")
    #expect(store.state.drift[original.id] == nil)
  }

  @Test func setDeferToSSHConfigPersistsToggle() async throws {
    let host = RemoteHost(sshAlias: "dev", importSource: .sshConfig, deferToSSHConfig: false)
    var state = RemoteHostsFeature.State()
    state.$hosts.withLock { $0 = [host] }
    let store = TestStore(initialState: state) {
      RemoteHostsFeature()
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.setDeferToSSHConfig(id: host.id, defer: true))
    #expect(store.state.hosts.first?.deferToSSHConfig == true)

    await store.send(.setDeferToSSHConfig(id: host.id, defer: false))
    #expect(store.state.hosts.first?.deferToSSHConfig == false)
  }

  @Test func failedReloadSurfacesErrorMessage() async throws {
    struct Boom: Error, LocalizedError {
      var errorDescription: String? { "no config file" }
    }
    let store = TestStore(initialState: RemoteHostsFeature.State()) {
      RemoteHostsFeature()
    } withDependencies: {
      $0.sshConfigClient = SSHConfigClient(
        listAliases: { throw Boom() },
        effectiveConfig: { _ in fatalError("unused") }
      )
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.reloadFromSSHConfig) { $0.isReloading = true }
    await store.receive(\._reloadFailed) {
      $0.isReloading = false
      $0.inlineError = "no config file"
    }
    #expect(store.state.hosts.isEmpty)
  }

  @Test func addManualHostCreatesNonImportedEntry() async throws {
    let store = TestStore(initialState: RemoteHostsFeature.State()) {
      RemoteHostsFeature()
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.addManualHost(sshAlias: "devbox"))
    #expect(store.state.hosts.map(\.sshAlias) == ["devbox"])
    #expect(store.state.hosts.first?.importSource == .manual)
    #expect(store.state.hosts.first?.importedFromSSHConfig == false)
    #expect(store.state.inlineError == nil)
  }

  @Test func addManualHostClearsForgottenAliasAndPreventsImportDuplicate() async throws {
    var state = RemoteHostsFeature.State()
    state.forgottenAliases = ["devbox"]
    let store = TestStore(initialState: state) {
      RemoteHostsFeature()
    } withDependencies: {
      $0.sshConfigClient = Self.sshConfig(aliases: ["devbox"])
      $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.addManualHost(sshAlias: "devbox"))
    #expect(store.state.forgottenAliases.isEmpty)
    #expect(store.state.hosts.map(\.sshAlias) == ["devbox"])

    await store.send(.reloadFromSSHConfig) { $0.isReloading = true }
    await store.receive(\._aliasesResolved) { $0.isReloading = false }
    #expect(store.state.hosts.map(\.sshAlias) == ["devbox"])
  }

  @Test func addManualHostRejectsDuplicateAlias() async throws {
    var state = RemoteHostsFeature.State()
    state.$hosts.withLock {
      $0 = [RemoteHost(sshAlias: "devbox")]
    }
    let store = TestStore(initialState: state) {
      RemoteHostsFeature()
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.addManualHost(sshAlias: "DEVBOX")) {
      $0.inlineError = "Remote host already exists."
    }
    #expect(store.state.hosts.count == 1)
  }

  @Test func renameHostPersists() async throws {
    let host = RemoteHost(sshAlias: "dev", importedFromSSHConfig: true)
    var state = RemoteHostsFeature.State()
    state.$hosts.withLock { $0 = [host] }
    let store = TestStore(initialState: state) {
      RemoteHostsFeature()
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.renameHost(id: host.id, newAlias: "Dev Box"))
    #expect(store.state.hosts.first?.alias == "Dev Box")
    #expect(store.state.hosts.first?.sshAlias == "dev")  // sshAlias is immutable
  }

  @Test func updateOverridesPersists() async throws {
    let host = RemoteHost(sshAlias: "dev", importedFromSSHConfig: true)
    var state = RemoteHostsFeature.State()
    state.$hosts.withLock { $0 = [host] }
    let store = TestStore(initialState: state) {
      RemoteHostsFeature()
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    let newOverrides = RemoteHost.Overrides(
      remoteTmpdir: "/srv/tmp",
      defaultRemoteWorkspaceRoot: "/srv/code"
    )
    await store.send(.updateOverrides(id: host.id, overrides: newOverrides))
    #expect(store.state.hosts.first?.overrides.remoteTmpdir == "/srv/tmp")
    #expect(
      store.state.hosts.first?.overrides.defaultRemoteWorkspaceRoot == "/srv/code"
    )
  }

  // MARK: Shell-history import

  @Test func scanShellHistoryPopulatesCandidates() async throws {
    let candidates = [
      SSHHistoryCandidate(
        raw: "ssh jz@jack.local",
        user: "jz",
        hostname: "jack.local",
        port: nil,
        identityFile: nil,
        timesSeen: 3,
        lastSeenAt: Date(timeIntervalSince1970: 1_700_000_000)
      ),
    ]
    let store = TestStore(initialState: RemoteHostsFeature.State()) {
      RemoteHostsFeature()
    } withDependencies: {
      $0.sshHistoryClient = SSHHistoryClient(
        listCandidates: { candidates }
      )
      $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.scanShellHistory) { $0.isScanningHistory = true }
    await store.receive(\._historyCandidatesLoaded) { $0.isScanningHistory = false }

    #expect(store.state.historyCandidates.count == 1)
    #expect(store.state.historyCandidates.first?.hostname == "jack.local")
  }

  @Test func scanShellHistoryFiltersCandidatesMatchingExistingHosts() async throws {
    let existing = RemoteHost(
      sshAlias: "jack.local",
      connection: RemoteHost.Connection(user: "jz", hostname: "jack.local"),
      importSource: .shellHistory
    )
    var state = RemoteHostsFeature.State()
    state.$hosts.withLock { $0 = [existing] }
    let candidates = [
      SSHHistoryCandidate(
        raw: "ssh jz@jack.local",
        user: "jz",
        hostname: "jack.local",
        port: nil,
        identityFile: nil,
        timesSeen: 1,
        lastSeenAt: nil
      ),
      SSHHistoryCandidate(
        raw: "ssh other@other.box",
        user: "other",
        hostname: "other.box",
        port: nil,
        identityFile: nil,
        timesSeen: 1,
        lastSeenAt: nil
      ),
    ]
    let store = TestStore(initialState: state) {
      RemoteHostsFeature()
    } withDependencies: {
      $0.sshHistoryClient = SSHHistoryClient(listCandidates: { candidates })
      $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.scanShellHistory)
    await store.receive(\._historyCandidatesLoaded)

    // Only the non-matching candidate is surfaced.
    #expect(store.state.historyCandidates.map(\.hostname) == ["other.box"])
  }

  @Test func importHistoryCandidatesCreatesRows() async throws {
    let candidate = SSHHistoryCandidate(
      raw: "ssh -p 2222 -i ~/id jz@jack.local",
      user: "jz",
      hostname: "jack.local",
      port: 2222,
      identityFile: "~/id",
      timesSeen: 5,
      lastSeenAt: nil
    )
    var state = RemoteHostsFeature.State()
    state.historyCandidates = [candidate]
    let store = TestStore(initialState: state) {
      RemoteHostsFeature()
    } withDependencies: {
      $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.importHistoryCandidates([candidate]))

    let host = try #require(store.state.hosts.first)
    #expect(host.sshAlias == "jack.local")
    #expect(host.connection.user == "jz")
    #expect(host.connection.port == 2222)
    #expect(host.connection.identityFile == "~/id")
    #expect(host.importSource == .shellHistory)
    #expect(host.deferToSSHConfig == false)
    // Imported candidate drops out of the pending list.
    #expect(store.state.historyCandidates.isEmpty)
  }

  @Test func historyScanFailureSurfacesError() async throws {
    struct Boom: Error, LocalizedError {
      var errorDescription: String? { "permission denied" }
    }
    let store = TestStore(initialState: RemoteHostsFeature.State()) {
      RemoteHostsFeature()
    } withDependencies: {
      $0.sshHistoryClient = SSHHistoryClient(listCandidates: { throw Boom() })
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.scanShellHistory) { $0.isScanningHistory = true }
    await store.receive(\._historyScanFailed) {
      $0.isScanningHistory = false
      $0.inlineError = "permission denied"
    }
  }

  @Test func forgetAliasRemovesAndMarksSticky() async throws {
    let host = RemoteHost(sshAlias: "staging", importedFromSSHConfig: true)
    var state = RemoteHostsFeature.State()
    state.$hosts.withLock { $0 = [host] }
    let store = TestStore(initialState: state) {
      RemoteHostsFeature()
    } withDependencies: {
      $0.sshConfigClient = Self.sshConfig(aliases: ["staging"])
      $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.forgetAlias(sshAlias: "staging"))
    #expect(store.state.hosts.isEmpty)
    #expect(store.state.forgottenAliases.contains("staging"))

    // Subsequent reload must NOT re-add the forgotten alias.
    await store.send(.reloadFromSSHConfig)
    await store.receive(\._aliasesResolved)
    #expect(store.state.hosts.isEmpty)
  }
}
