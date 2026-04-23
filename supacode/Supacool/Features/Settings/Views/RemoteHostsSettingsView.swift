import ComposableArchitecture
import SwiftUI

/// Settings panel for `RemoteHostsFeature`. Lives in the upstream
/// Settings shell by reading `SettingsSection.remoteHosts` — the only
/// other upstream change is the enum case + a sidebar label + the switch
/// branch in `SettingsView`.
///
/// Owns its own `StoreOf<RemoteHostsFeature>` because the feature doesn't
/// currently plug into `SettingsFeature`; the reducer's state is all
/// derived from `@Shared(.remoteHosts)` so there's no coupling cost.
struct RemoteHostsSettingsView: View {
  @State private var store = Store(initialState: RemoteHostsFeature.State()) {
    RemoteHostsFeature()
  }
  @State private var manualSSHAliasDraft: String = ""
  @State private var historyExpanded: Bool = false
  @State private var historySelection: Set<SSHHistoryCandidate.ID> = []
  @State private var historyScanTriggered: Bool = false

  var body: some View {
    Form {
      Section {
        header
        manualAddRow
        if store.hosts.isEmpty {
          emptyState
        } else {
          if !store.drift.isEmpty {
            driftBanner
          }
          ForEach(store.hosts) { host in
            RemoteHostRow(
              host: host,
              drift: store.drift[host.id],
              onRename: { newAlias in
                store.send(.renameHost(id: host.id, newAlias: newAlias))
              },
              onUpdateOverrides: { overrides in
                store.send(.updateOverrides(id: host.id, overrides: overrides))
              },
              onUpdateConnection: { connection in
                store.send(.updateConnection(id: host.id, connection: connection))
              },
              onToggleDefer: { deferFlag in
                store.send(.setDeferToSSHConfig(id: host.id, defer: deferFlag))
              },
              onReimport: host.importSource == .sshConfig && store.drift[host.id] != nil
                ? { store.send(.reimportRow(id: host.id)) }
                : nil,
              onForget: {
                if host.importedFromSSHConfig {
                  store.send(.forgetAlias(sshAlias: host.sshAlias))
                } else {
                  store.send(.removeHost(id: host.id))
                }
              }
            )
          }
        }
        if let message = store.inlineError {
          Text(message)
            .font(.caption)
            .foregroundStyle(.red)
        }
      }
      historySection
    }
    .formStyle(.grouped)
    .navigationTitle("Remote Hosts")
    .task { store.send(.appeared) }
  }

  @ViewBuilder
  private var historySection: some View {
    Section {
      DisclosureGroup(isExpanded: $historyExpanded) {
        historyContents
      } label: {
        HStack(spacing: 8) {
          Image(systemName: "clock.arrow.circlepath")
            .foregroundStyle(.secondary)
          Text("Found in shell history")
            .font(.body.weight(.medium))
          if !store.historyCandidates.isEmpty {
            Text("\(store.historyCandidates.count)")
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
          }
          Spacer()
          if store.isScanningHistory {
            ProgressView().controlSize(.small)
          }
        }
      }
      .onChange(of: historyExpanded) { _, expanded in
        if expanded, !historyScanTriggered {
          historyScanTriggered = true
          store.send(.scanShellHistory)
        }
      }
    } footer: {
      Text(
        "Supacool scans ~/.zsh_history and ~/.bash_history for `ssh user@host` "
          + "commands you've already run, so you can import them without editing ssh_config."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private var historyContents: some View {
    if store.isScanningHistory {
      Text("Scanning…")
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.vertical, 4)
    } else if store.historyCandidates.isEmpty {
      VStack(alignment: .leading, spacing: 4) {
        Text("No new hosts found in your shell history.")
          .font(.callout)
        Button("Scan again") {
          historySelection.removeAll()
          store.send(.scanShellHistory)
        }
        .controlSize(.small)
      }
      .padding(.vertical, 4)
    } else {
      ForEach(store.historyCandidates) { candidate in
        historyCandidateRow(candidate)
      }
      HStack {
        Button("Import selected (\(historySelection.count))") {
          let selected = store.historyCandidates.filter { historySelection.contains($0.id) }
          store.send(.importHistoryCandidates(selected))
          historySelection.removeAll()
        }
        .disabled(historySelection.isEmpty)
        Spacer()
        Button("Select all") {
          historySelection = Set(store.historyCandidates.map(\.id))
        }
        .controlSize(.small)
      }
      .padding(.top, 4)
    }
  }

  private func historyCandidateRow(_ candidate: SSHHistoryCandidate) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Toggle(
        "",
        isOn: Binding(
          get: { historySelection.contains(candidate.id) },
          set: { isOn in
            if isOn {
              historySelection.insert(candidate.id)
            } else {
              historySelection.remove(candidate.id)
            }
          }
        )
      )
      .labelsHidden()
      VStack(alignment: .leading, spacing: 2) {
        Text(candidateDisplay(candidate))
          .font(.body.monospaced())
        Text(candidateMetadata(candidate))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding(.vertical, 2)
  }

  private func candidateDisplay(_ candidate: SSHHistoryCandidate) -> String {
    var target = ""
    if let user = candidate.user { target += "\(user)@" }
    target += candidate.hostname
    if let port = candidate.port { target += ":\(port)" }
    return target
  }

  private func candidateMetadata(_ candidate: SSHHistoryCandidate) -> String {
    var bits = ["\(candidate.timesSeen) use\(candidate.timesSeen == 1 ? "" : "s")"]
    if let lastSeen = candidate.lastSeenAt {
      let days = Int(-lastSeen.timeIntervalSinceNow / 86400)
      if days == 0 {
        bits.append("today")
      } else if days == 1 {
        bits.append("1 day ago")
      } else {
        bits.append("\(days) days ago")
      }
    }
    if let identity = candidate.identityFile {
      bits.append(identity)
    }
    return bits.joined(separator: " · ")
  }

  private var header: some View {
    HStack {
      Text(
        """
        Auto-imported from ~/.ssh/config. Supacool stores User / Hostname / \
        Port / Identity file on each host so you can edit them here — changes \
        never modify your ssh_config. Use "Defer to ssh_config" for hosts \
        that need ProxyJump or Match directives.
        """
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      Spacer()
      Button {
        store.send(.reloadFromSSHConfig)
      } label: {
        if store.isReloading {
          ProgressView().controlSize(.small)
        } else {
          Label("Reload", systemImage: "arrow.clockwise")
        }
      }
      .disabled(store.isReloading)
      .help("Re-read ~/.ssh/config and import any new aliases")
    }
  }

  private var driftBanner: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.yellow)
      Text(
        "ssh_config changed for \(store.drift.count) host\(store.drift.count == 1 ? "" : "s") "
          + "since last import."
      )
      .font(.callout)
      Spacer()
      Button("Re-import all") { store.send(.reimportAll) }
        .controlSize(.small)
    }
    .padding(.vertical, 4)
  }

  private var manualAddRow: some View {
    HStack(alignment: .firstTextBaseline) {
      Text("Manual host")
        .foregroundStyle(.secondary)
        .frame(width: 160, alignment: .leading)
      HStack(spacing: 8) {
        TextField("SSH alias (what `ssh <alias>` uses)", text: $manualSSHAliasDraft)
          .textFieldStyle(.roundedBorder)
          .onSubmit(addManualHost)
        Button("Add", action: addManualHost)
          .disabled(manualSSHAliasDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
  }

  private var emptyState: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("No remote hosts yet.")
        .font(.callout)
      Text("Supacool looks for top-level `Host` entries in `~/.ssh/config`.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 6)
  }

  private func addManualHost() {
    let trimmed = manualSSHAliasDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let previousCount = store.hosts.count
    store.send(.addManualHost(sshAlias: trimmed))
    if store.hosts.count > previousCount {
      manualSSHAliasDraft = ""
    }
  }
}

/// One row per host. Expanding the disclosure reveals the connection
/// fields (User / Hostname / Port / Identity), the Supacool-only
/// overrides (tmpdir, default workspace root, notes), and the
/// "Defer to ssh_config" escape hatch.
private struct RemoteHostRow: View {
  let host: RemoteHost
  let drift: RemoteHostsFeature.DriftReport?
  let onRename: (String) -> Void
  let onUpdateOverrides: (RemoteHost.Overrides) -> Void
  let onUpdateConnection: (RemoteHost.Connection) -> Void
  let onToggleDefer: (Bool) -> Void
  let onReimport: (() -> Void)?
  let onForget: () -> Void

  @State private var aliasDraft: String = ""
  @State private var userDraft: String = ""
  @State private var hostnameDraft: String = ""
  @State private var portDraft: String = ""
  @State private var identityFileDraft: String = ""
  @State private var tmpdirDraft: String = ""
  @State private var rootDraft: String = ""
  @State private var notesDraft: String = ""
  @State private var isExpanded: Bool = false

  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      detailForm
    } label: {
      rowHeader
    }
    .task(id: host.id) { syncDraftsFromHost() }
    .task(id: host.connection) { syncDraftsFromHost() }
  }

  private var rowHeader: some View {
    HStack(spacing: 8) {
      Image(systemName: "network")
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 2) {
        Text(host.alias)
          .font(.body.weight(.medium))
        HStack(spacing: 6) {
          Text(host.sshAlias)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
          sourceBadge
          if drift != nil {
            Label("ssh_config changed", systemImage: "exclamationmark.triangle.fill")
              .labelStyle(.titleAndIcon)
              .font(.caption)
              .foregroundStyle(.yellow)
          }
        }
      }
      Spacer()
      Button(role: .destructive, action: onForget) {
        Image(systemName: "minus.circle")
      }
      .buttonStyle(.plain)
      .help(
        host.importedFromSSHConfig
          ? "Hide this imported host (won't come back unless you edit ssh_config)"
          : "Remove this host"
      )
    }
  }

  @ViewBuilder
  private var sourceBadge: some View {
    switch host.importSource {
    case .sshConfig:
      Text("from ~/.ssh/config")
        .font(.caption)
        .foregroundStyle(.tertiary)
    case .shellHistory:
      Text("from shell history")
        .font(.caption)
        .foregroundStyle(.tertiary)
    case .manual:
      EmptyView()
    }
  }

  @ViewBuilder
  private var detailForm: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let onReimport {
        HStack {
          Button("Re-import from ssh_config", action: onReimport)
            .controlSize(.small)
          Spacer()
        }
        .padding(.bottom, 2)
      }
      labeledField(
        "Display name",
        placeholder: host.sshAlias,
        text: $aliasDraft,
        onCommit: {
          if aliasDraft != host.alias, !aliasDraft.isEmpty {
            onRename(aliasDraft)
          }
        }
      )
      connectionFields
      Divider().padding(.vertical, 2)
      labeledField(
        "Remote tmpdir",
        placeholder: "/tmp",
        text: $tmpdirDraft,
        onCommit: { commitOverrides() }
      )
      labeledField(
        "Default workspace root",
        placeholder: "(optional, e.g. /home/jz/code)",
        text: $rootDraft,
        onCommit: { commitOverrides() }
      )
      labeledField(
        "Notes",
        placeholder: "(optional)",
        text: $notesDraft,
        onCommit: { commitOverrides() }
      )
      deferRow
    }
    .padding(.top, 6)
    .padding(.bottom, 4)
  }

  @ViewBuilder
  private var connectionFields: some View {
    labeledField(
      "User",
      placeholder: "(optional)",
      text: $userDraft,
      highlight: drift?.userChanged ?? false,
      onCommit: { commitConnection() }
    )
    labeledField(
      "Hostname",
      placeholder: host.sshAlias,
      text: $hostnameDraft,
      highlight: drift?.hostnameChanged ?? false,
      onCommit: { commitConnection() }
    )
    labeledField(
      "Port",
      placeholder: "22",
      text: $portDraft,
      highlight: drift?.portChanged ?? false,
      onCommit: { commitConnection() }
    )
    labeledField(
      "Identity file",
      placeholder: "(optional, e.g. ~/.ssh/id_ed25519)",
      text: $identityFileDraft,
      highlight: drift?.identityFileChanged ?? false,
      onCommit: { commitConnection() }
    )
  }

  @ViewBuilder
  private var deferRow: some View {
    HStack(alignment: .firstTextBaseline) {
      Text("Runtime")
        .foregroundStyle(.secondary)
        .frame(width: 160, alignment: .leading)
      VStack(alignment: .leading, spacing: 4) {
        Toggle(
          "Defer to ssh_config (run `ssh \(host.sshAlias)`)",
          isOn: Binding(
            get: { host.deferToSSHConfig },
            set: { onToggleDefer($0) }
          )
        )
        .toggleStyle(.checkbox)
        Text(
          host.deferToSSHConfig
            ? "OpenSSH resolves User / Hostname / Port / Identity — the fields above are ignored."
            : "Supacool uses the fields above; ssh_config isn't consulted."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func labeledField(
    _ label: String,
    placeholder: String,
    text: Binding<String>,
    highlight: Bool = false,
    onCommit: @escaping () -> Void
  ) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(label)
        .foregroundStyle(.secondary)
        .frame(width: 160, alignment: .leading)
      TextField(placeholder, text: text)
        .textFieldStyle(.roundedBorder)
        .overlay(
          RoundedRectangle(cornerRadius: 6)
            .stroke(.yellow, lineWidth: highlight ? 1 : 0)
        )
        .onSubmit(onCommit)
      if highlight {
        Image(systemName: "exclamationmark.circle")
          .foregroundStyle(.yellow)
          .help("This field changed in ssh_config since last import.")
      }
    }
  }

  private func syncDraftsFromHost() {
    aliasDraft = host.alias
    userDraft = host.connection.user ?? ""
    hostnameDraft = host.connection.hostname ?? ""
    portDraft = host.connection.port.map(String.init) ?? ""
    identityFileDraft = host.connection.identityFile ?? ""
    tmpdirDraft = host.overrides.remoteTmpdir ?? ""
    rootDraft = host.overrides.defaultRemoteWorkspaceRoot ?? ""
    notesDraft = host.overrides.notes ?? ""
  }

  private func commitOverrides() {
    let overrides = RemoteHost.Overrides(
      remoteTmpdir: tmpdirDraft.isEmpty ? nil : tmpdirDraft,
      defaultRemoteWorkspaceRoot: rootDraft.isEmpty ? nil : rootDraft,
      notes: notesDraft.isEmpty ? nil : notesDraft
    )
    if overrides != host.overrides {
      onUpdateOverrides(overrides)
    }
  }

  private func commitConnection() {
    let trimmedPort = portDraft.trimmingCharacters(in: .whitespaces)
    let connection = RemoteHost.Connection(
      user: userDraft.isEmpty ? nil : userDraft,
      hostname: hostnameDraft.isEmpty ? nil : hostnameDraft,
      port: Int(trimmedPort),
      identityFile: identityFileDraft.isEmpty ? nil : identityFileDraft
    )
    if connection != host.connection {
      onUpdateConnection(connection)
    }
  }
}
