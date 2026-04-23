import ComposableArchitecture
import Foundation

private nonisolated let remoteHostsLogger = SupaLogger("Supacool.RemoteHosts")

/// Owns the `RemoteHost` catalog. Three responsibilities:
///
/// 1. **Import.** On `.appeared` (and on an explicit `.reloadFromSSHConfig`),
///    diff the user's `~/.ssh/config` aliases against the persisted
///    catalog and insert any that are new. For each new entry we also
///    fan out `ssh -G <alias>` and seed `RemoteHost.connection` from the
///    resolved values. Missing aliases are NOT auto-deleted — the user
///    may want to keep the Supacool overrides even if an entry is
///    temporarily commented out of ssh_config.
///
/// 2. **Drift detection.** For rows already in the catalog whose
///    `importSource == .sshConfig`, compare the stored `connection`
///    against a fresh `ssh -G`. Divergence is surfaced as a transient
///    `drift` entry so the UI can render a "ssh_config changed since
///    import" hint + an explicit Re-import button. Never auto-overwrites.
///
/// 3. **Overrides + connection CRUD.** Edit `remoteTmpdir` /
///    `defaultRemoteWorkspaceRoot` / `notes`, rename the alias, toggle
///    `deferToSSHConfig`, edit `user` / `hostname` / `port` /
///    `identityFile`, or remove a host entirely.
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
    /// Transient divergence between stored `connection` and the latest
    /// `ssh -G` output. Keyed by host id; populated during reloads;
    /// cleared when the user clicks Re-import.
    var drift: [RemoteHost.ID: DriftReport] = [:]
    /// Dedup'd `ssh` invocations observed in the user's shell history
    /// that aren't already represented in `hosts`. Populated by
    /// `.scanShellHistory`; cleared after `.importHistoryCandidates` as
    /// matching targets drop out of the filter.
    var historyCandidates: [SSHHistoryCandidate] = []
    /// `true` while a history scan is in flight; hides the "Scan again"
    /// affordance so it can't be retriggered concurrently.
    var isScanningHistory: Bool = false
  }

  /// Captures which flat connection fields diverged during a reload so
  /// the UI can render a yellow badge and offer "Re-import" on a row.
  nonisolated struct DriftReport: Equatable, Sendable {
    let userChanged: Bool
    let hostnameChanged: Bool
    let portChanged: Bool
    let identityFileChanged: Bool
    /// The fresh config we observed; applied on `.reimportRow` /
    /// `.reimportAll` rather than being recomputed.
    let fresh: EffectiveSSHConfig

    var isEmpty: Bool {
      !userChanged && !hostnameChanged && !portChanged && !identityFileChanged
    }
  }

  enum Action: Equatable {
    // Lifecycle
    case appeared
    case reloadFromSSHConfig

    // Internal effects
    case _aliasesResolved([ResolvedAlias])
    case _reloadFailed(String)

    // Host CRUD
    case addManualHost(sshAlias: String)
    case renameHost(id: RemoteHost.ID, newAlias: String)
    case updateOverrides(id: RemoteHost.ID, overrides: RemoteHost.Overrides)
    case updateConnection(id: RemoteHost.ID, connection: RemoteHost.Connection)
    case setDeferToSSHConfig(id: RemoteHost.ID, defer: Bool)
    case reimportRow(id: RemoteHost.ID)
    case reimportAll
    case removeHost(id: RemoteHost.ID)
    case forgetAlias(sshAlias: String)

    // Shell-history bootstrap
    case scanShellHistory
    case _historyCandidatesLoaded([SSHHistoryCandidate])
    case _historyScanFailed(String)
    case importHistoryCandidates([SSHHistoryCandidate])
  }

  /// Intermediate result from the fan-out — `ssh -G` either succeeded
  /// for this alias or didn't. Failures are non-fatal (we log + continue)
  /// so one misconfigured alias doesn't block the rest of the import.
  nonisolated struct ResolvedAlias: Equatable, Sendable {
    let alias: String
    let config: EffectiveSSHConfig?
  }

  @Dependency(SSHConfigClient.self) var sshConfigClient
  @Dependency(SSHHistoryClient.self) var sshHistoryClient
  @Dependency(\.date.now) var now

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
            let resolved = await Self.fanOutEffectiveConfig(
              aliases: aliases,
              client: sshConfigClient
            )
            await send(._aliasesResolved(resolved))
          } catch {
            remoteHostsLogger.warning("ssh config reload failed: \(error.localizedDescription)")
            await send(._reloadFailed(error.localizedDescription))
          }
        }
        .cancellable(id: CancelID.reload, cancelInFlight: true)

      case ._aliasesResolved(let resolved):
        state.isReloading = false
        let existingByAlias = Dictionary(
          uniqueKeysWithValues: state.hosts.map { ($0.sshAlias, $0) }
        )
        var additions: [RemoteHost] = []
        var newDrift: [RemoteHost.ID: DriftReport] = [:]
        let stamp = now

        for entry in resolved {
          if let existing = existingByAlias[entry.alias] {
            // Host already known. Compute drift if we have fresh config
            // and the existing row came from ssh_config — other sources
            // (manual / history) don't drift by definition.
            guard
              existing.importSource == .sshConfig,
              let fresh = entry.config
            else { continue }
            let report = Self.detectDrift(stored: existing.connection, fresh: fresh)
            if !report.isEmpty {
              newDrift[existing.id] = report
            }
          } else {
            // Skip explicit forgotten aliases and aliases we couldn't resolve
            // but still want to register with zero connection info so the
            // user can fill them in manually.
            guard !state.forgottenAliases.contains(entry.alias) else { continue }
            let connection = entry.config.map(Self.connection(from:)) ?? RemoteHost.Connection()
            let deferFlag = entry.config?.hasComplexDirectives ?? true
            additions.append(
              RemoteHost(
                sshAlias: entry.alias,
                connection: connection,
                importSource: .sshConfig,
                importedAt: entry.config != nil ? stamp : nil,
                deferToSSHConfig: deferFlag
              )
            )
          }
        }

        if !additions.isEmpty {
          state.$hosts.withLock { $0.append(contentsOf: additions) }
        }
        state.drift = newDrift
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

      case .updateConnection(let id, let connection):
        state.$hosts.withLock { hosts in
          guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
          hosts[index].connection = connection
        }
        // Any manual edit clears the drift badge for this row — the user
        // has explicitly overridden whatever ssh_config now says.
        state.drift[id] = nil
        return .none

      case .setDeferToSSHConfig(let id, let deferFlag):
        state.$hosts.withLock { hosts in
          guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
          hosts[index].deferToSSHConfig = deferFlag
        }
        return .none

      case .reimportRow(let id):
        guard let report = state.drift[id] else { return .none }
        Self.apply(fresh: report.fresh, toHostID: id, in: &state, stamp: now)
        state.drift[id] = nil
        return .none

      case .reimportAll:
        for (id, report) in state.drift {
          Self.apply(fresh: report.fresh, toHostID: id, in: &state, stamp: now)
        }
        state.drift = [:]
        return .none

      case .removeHost(let id):
        state.$hosts.withLock { hosts in
          hosts.removeAll(where: { $0.id == id })
        }
        state.drift[id] = nil
        return .none

      case .forgetAlias(let sshAlias):
        state.forgottenAliases.insert(sshAlias)
        state.$hosts.withLock { hosts in
          hosts.removeAll(where: {
            $0.importSource == .sshConfig && $0.sshAlias == sshAlias
          })
        }
        return .none

      case .scanShellHistory:
        guard !state.isScanningHistory else { return .none }
        state.isScanningHistory = true
        return .run { [sshHistoryClient] send in
          do {
            let candidates = try await sshHistoryClient.listCandidates()
            await send(._historyCandidatesLoaded(candidates))
          } catch {
            remoteHostsLogger.warning(
              "Shell-history scan failed: \(error.localizedDescription)"
            )
            await send(._historyScanFailed(error.localizedDescription))
          }
        }
        .cancellable(id: CancelID.historyScan, cancelInFlight: true)

      case ._historyCandidatesLoaded(let candidates):
        state.isScanningHistory = false
        // Filter out candidates whose (user, hostname, port) already
        // matches a stored host's `connection` — re-imports should be
        // explicit (Reload button), not accidental.
        state.historyCandidates = candidates.filter { candidate in
          !state.hosts.contains { host in
            let hostname = host.connection.hostname ?? host.sshAlias
            return host.connection.user == candidate.user
              && hostname == candidate.hostname
              && host.connection.port == candidate.port
          }
        }
        return .none

      case ._historyScanFailed(let message):
        state.isScanningHistory = false
        state.inlineError = message
        return .none

      case .importHistoryCandidates(let selected):
        let stamp = now
        var newHosts: [RemoteHost] = []
        for candidate in selected {
          // sshAlias defaults to the raw hostname so existing "find by
          // alias" lookups (including in spawn flows) still work. User
          // can rename in-place afterwards.
          let connection = RemoteHost.Connection(
            user: candidate.user,
            hostname: candidate.hostname,
            port: candidate.port,
            identityFile: candidate.identityFile
          )
          newHosts.append(
            RemoteHost(
              sshAlias: candidate.hostname,
              connection: connection,
              importSource: .shellHistory,
              importedAt: stamp,
              deferToSSHConfig: false
            )
          )
        }
        if !newHosts.isEmpty {
          state.$hosts.withLock { $0.append(contentsOf: newHosts) }
        }
        // Drop imported candidates from the pending list.
        let importedKeys = Set(selected.map(\.id))
        state.historyCandidates.removeAll { importedKeys.contains($0.id) }
        return .none
      }
    }
  }

  private nonisolated enum CancelID: Hashable { case reload, historyScan }

  // MARK: - Helpers

  /// Fan-out `ssh -G` calls with a small concurrency cap so a `~/.ssh/config`
  /// with dozens of entries doesn't open dozens of `ssh` processes at once.
  /// Failures are swallowed into `config: nil` so one broken alias doesn't
  /// abort the whole reload.
  nonisolated static func fanOutEffectiveConfig(
    aliases: [String],
    client: SSHConfigClient,
    maxConcurrent: Int = 8
  ) async -> [ResolvedAlias] {
    await withTaskGroup(of: ResolvedAlias.self) { group in
      var iterator = aliases.makeIterator()
      var inFlight = 0

      func addNext() {
        guard let next = iterator.next() else { return }
        inFlight += 1
        group.addTask {
          do {
            let config = try await client.effectiveConfig(next)
            return ResolvedAlias(alias: next, config: config)
          } catch {
            remoteHostsLogger.warning(
              "ssh -G failed for \(next): \(error.localizedDescription)"
            )
            return ResolvedAlias(alias: next, config: nil)
          }
        }
      }

      for _ in 0..<min(maxConcurrent, aliases.count) { addNext() }

      var results: [ResolvedAlias] = []
      for await resolved in group {
        results.append(resolved)
        inFlight -= 1
        addNext()
      }
      // Preserve input order so the Settings UI stays stable across reloads.
      let orderIndex = Dictionary(
        uniqueKeysWithValues: aliases.enumerated().map { ($1, $0) }
      )
      results.sort {
        (orderIndex[$0.alias] ?? Int.max) < (orderIndex[$1.alias] ?? Int.max)
      }
      return results
    }
  }

  nonisolated static func connection(from eff: EffectiveSSHConfig) -> RemoteHost.Connection {
    RemoteHost.Connection(
      user: eff.user,
      hostname: eff.hostname,
      port: eff.port,
      identityFile: eff.identityFiles.first
    )
  }

  nonisolated static func detectDrift(
    stored: RemoteHost.Connection,
    fresh: EffectiveSSHConfig
  ) -> DriftReport {
    let freshConnection = connection(from: fresh)
    return DriftReport(
      userChanged: stored.user != freshConnection.user,
      hostnameChanged: stored.hostname != freshConnection.hostname,
      portChanged: stored.port != freshConnection.port,
      identityFileChanged: stored.identityFile != freshConnection.identityFile,
      fresh: fresh
    )
  }

  private static func apply(
    fresh: EffectiveSSHConfig,
    toHostID id: RemoteHost.ID,
    in state: inout State,
    stamp: Date
  ) {
    let freshConnection = connection(from: fresh)
    let deferFlag = fresh.hasComplexDirectives
    state.$hosts.withLock { hosts in
      guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
      hosts[index].connection = freshConnection
      hosts[index].importedAt = stamp
      hosts[index].deferToSSHConfig = deferFlag
    }
  }
}
