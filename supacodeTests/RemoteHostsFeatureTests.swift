import ComposableArchitecture
import Foundation
import Testing

@testable import Supacool

/// Covers the import-and-diff behaviour users rely on every time they add
/// or remove a host from `~/.ssh/config`: new aliases show up, existing
/// aliases don't double-insert, explicitly-forgotten aliases stay gone,
/// and override edits survive a reload.
@MainActor
struct RemoteHostsFeatureTests {

  @Test func appearedImportsAliasesOnce() async throws {
    let store = TestStore(initialState: RemoteHostsFeature.State()) {
      RemoteHostsFeature()
    } withDependencies: {
      $0.sshConfigClient = SSHConfigClient(
        listAliases: { ["dev", "prod"] },
        effectiveConfig: { _ in fatalError("unused") }
      )
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.appeared) { $0.isReloading = true }
    await store.receive(\._aliasesLoaded) { $0.isReloading = false }

    #expect(store.state.hosts.count == 2)
    #expect(store.state.hosts.map(\.sshAlias) == ["dev", "prod"])
    let allImported = store.state.hosts.allSatisfy { $0.importedFromSSHConfig }
    #expect(allImported)
  }

  @Test func reloadDoesNotDuplicateExistingAliases() async throws {
    var state = RemoteHostsFeature.State()
    state.$hosts.withLock {
      $0 = [RemoteHost(sshAlias: "dev", importedFromSSHConfig: true)]
    }
    let store = TestStore(initialState: state) {
      RemoteHostsFeature()
    } withDependencies: {
      $0.sshConfigClient = SSHConfigClient(
        listAliases: { ["dev", "prod"] },
        effectiveConfig: { _ in fatalError("unused") }
      )
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.reloadFromSSHConfig)
    await store.receive(\._aliasesLoaded)

    #expect(store.state.hosts.map(\.sshAlias) == ["dev", "prod"])
  }

  @Test func reloadSkipsForgottenAliases() async throws {
    var state = RemoteHostsFeature.State()
    state.forgottenAliases = ["staging"]
    let store = TestStore(initialState: state) {
      RemoteHostsFeature()
    } withDependencies: {
      $0.sshConfigClient = SSHConfigClient(
        listAliases: { ["dev", "staging"] },
        effectiveConfig: { _ in fatalError("unused") }
      )
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.reloadFromSSHConfig)
    await store.receive(\._aliasesLoaded)

    #expect(store.state.hosts.map(\.sshAlias) == ["dev"])
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
      $0.lastImportError = "no config file"
    }
    #expect(store.state.hosts.isEmpty)
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

  @Test func forgetAliasRemovesAndMarksSticky() async throws {
    let host = RemoteHost(sshAlias: "staging", importedFromSSHConfig: true)
    var state = RemoteHostsFeature.State()
    state.$hosts.withLock { $0 = [host] }
    let store = TestStore(initialState: state) {
      RemoteHostsFeature()
    } withDependencies: {
      $0.sshConfigClient = SSHConfigClient(
        listAliases: { ["staging"] },
        effectiveConfig: { _ in fatalError("unused") }
      )
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.forgetAlias(sshAlias: "staging"))
    #expect(store.state.hosts.isEmpty)
    #expect(store.state.forgottenAliases.contains("staging"))

    // Subsequent reload must NOT re-add the forgotten alias.
    await store.send(.reloadFromSSHConfig)
    await store.receive(\._aliasesLoaded)
    #expect(store.state.hosts.isEmpty)
  }
}
