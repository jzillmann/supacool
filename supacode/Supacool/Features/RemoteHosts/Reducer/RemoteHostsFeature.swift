import ComposableArchitecture
import Foundation

private nonisolated let remoteHostsLogger = SupaLogger("Supacool.RemoteHosts")

/// Owns the `RemoteHost` catalog. Two responsibilities:
///
/// 1. **Import.** On `.appeared` (and on an explicit `.reloadFromSSHConfig`),
///    diff the user's `~/.ssh/config` aliases against the persisted
///    catalog and insert any that are new. Missing aliases are NOT
///    auto-deleted — the user may want to keep the Supacool overrides
///    even if an entry is temporarily commented out of ssh_config.
///
/// 2. **Overrides CRUD.** Edit `remoteTmpdir` / `defaultRemoteWorkspaceRoot`
///    / `notes`, rename the alias, or remove a host entirely (including
///    imported ones — the next reload will bring it back if ssh_config
///    still declares it, unless `forgottenAliases` says otherwise).
@Reducer
struct RemoteHostsFeature {
  @ObservableState
  struct State: Equatable {
    @Shared(.remoteHosts) var hosts: [RemoteHost] = []
    /// SSH-config aliases the user explicitly removed. The importer skips
    /// these on reload so a manual delete stays sticky. Cleared if the
    /// user re-adds the host via a future "Unhide" affordance.
    var forgottenAliases: Set<String> = []
    /// Inline settings error shown for reload failures and manual-entry
    /// validation so the user can see why nothing changed.
    var inlineError: String?
    /// True while a reload is in flight; disables the Reload button.
    var isReloading: Bool = false
  }

  enum Action: Equatable {
    // Lifecycle
    case appeared
    case reloadFromSSHConfig

    // Internal effects
    case _aliasesLoaded([String])
    case _reloadFailed(String)

    // Host CRUD
    case addManualHost(sshAlias: String)
    case renameHost(id: RemoteHost.ID, newAlias: String)
    case updateOverrides(id: RemoteHost.ID, overrides: RemoteHost.Overrides)
    case removeHost(id: RemoteHost.ID)
    case forgetAlias(sshAlias: String)
  }

  @Dependency(SSHConfigClient.self) var sshConfigClient

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .appeared, .reloadFromSSHConfig:
        guard !state.isReloading else { return .none }
        state.isReloading = true
        state.inlineError = nil
        return .run { [sshConfigClient] send in
          do {
            let aliases = try await sshConfigClient.listAliases()
            await send(._aliasesLoaded(aliases))
          } catch {
            remoteHostsLogger.warning("ssh config reload failed: \(error.localizedDescription)")
            await send(._reloadFailed(error.localizedDescription))
          }
        }
        .cancellable(id: CancelID.reload, cancelInFlight: true)

      case ._aliasesLoaded(let aliases):
        state.isReloading = false
        let existing = Set(state.hosts.map(\.sshAlias))
        let additions =
          aliases
          .filter { !existing.contains($0) }
          .filter { !state.forgottenAliases.contains($0) }
          .map { alias in
            RemoteHost(sshAlias: alias, importedFromSSHConfig: true)
          }
        if !additions.isEmpty {
          state.$hosts.withLock { $0.append(contentsOf: additions) }
        }
        return .none

      case ._reloadFailed(let message):
        state.isReloading = false
        state.inlineError = message
        return .none

      case .addManualHost(let sshAlias):
        let trimmed = sshAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
          state.inlineError = "SSH alias required."
          return .none
        }
        let alreadyExists = state.hosts.contains {
          $0.sshAlias.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
        }
        guard !alreadyExists else {
          state.inlineError = "Remote host already exists."
          return .none
        }
        state.inlineError = nil
        state.forgottenAliases.remove(trimmed)
        state.$hosts.withLock { hosts in
          hosts.append(RemoteHost(sshAlias: trimmed))
        }
        return .none

      case .renameHost(let id, let newAlias):
        let trimmed = newAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }
        state.$hosts.withLock { hosts in
          guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
          hosts[index].alias = trimmed
        }
        return .none

      case .updateOverrides(let id, let overrides):
        state.$hosts.withLock { hosts in
          guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
          hosts[index].overrides = overrides
        }
        return .none

      case .removeHost(let id):
        state.$hosts.withLock { hosts in
          hosts.removeAll(where: { $0.id == id })
        }
        return .none

      case .forgetAlias(let sshAlias):
        state.forgottenAliases.insert(sshAlias)
        state.$hosts.withLock { hosts in
          hosts.removeAll(where: {
            $0.importedFromSSHConfig && $0.sshAlias == sshAlias
          })
        }
        return .none
      }
    }
  }

  private nonisolated enum CancelID: Hashable { case reload }
}
