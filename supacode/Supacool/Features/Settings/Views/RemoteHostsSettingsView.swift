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

  var body: some View {
    Form {
      Section {
        header
        manualAddRow
        if store.hosts.isEmpty {
          emptyState
        } else {
          ForEach(store.hosts) { host in
            RemoteHostRow(
              host: host,
              onRename: { newAlias in
                store.send(.renameHost(id: host.id, newAlias: newAlias))
              },
              onUpdateOverrides: { overrides in
                store.send(.updateOverrides(id: host.id, overrides: overrides))
              },
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
    }
    .formStyle(.grouped)
    .navigationTitle("Remote Hosts")
    .task { store.send(.appeared) }
  }

  private var header: some View {
    HStack {
      Text(
        """
        Auto-imported from ~/.ssh/config. Overrides you set here (remote \
        tmpdir, default workspace root) are Supacool-only — they don't modify \
        your ssh_config.
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

/// One row per host. Expanding the disclosure reveals the Supacool-only
/// overrides (tmpdir, default workspace root, notes).
private struct RemoteHostRow: View {
  let host: RemoteHost
  let onRename: (String) -> Void
  let onUpdateOverrides: (RemoteHost.Overrides) -> Void
  let onForget: () -> Void

  @State private var aliasDraft: String = ""
  @State private var tmpdirDraft: String = ""
  @State private var rootDraft: String = ""
  @State private var notesDraft: String = ""
  @State private var isExpanded: Bool = false

  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      overridesForm
    } label: {
      rowHeader
    }
    .task(id: host.id) { syncDraftsFromHost() }
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
          if host.importedFromSSHConfig {
            Text("from ~/.ssh/config")
              .font(.caption)
              .foregroundStyle(.tertiary)
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
  private var overridesForm: some View {
    VStack(alignment: .leading, spacing: 10) {
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
    }
    .padding(.top, 6)
    .padding(.bottom, 4)
  }

  private func labeledField(
    _ label: String,
    placeholder: String,
    text: Binding<String>,
    onCommit: @escaping () -> Void
  ) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(label)
        .foregroundStyle(.secondary)
        .frame(width: 160, alignment: .leading)
      TextField(placeholder, text: text)
        .textFieldStyle(.roundedBorder)
        .onSubmit(onCommit)
    }
  }

  private func syncDraftsFromHost() {
    aliasDraft = host.alias
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
}
