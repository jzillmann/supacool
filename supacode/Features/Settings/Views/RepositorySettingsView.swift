import ComposableArchitecture
import SwiftUI

struct RepositorySettingsView: View {
  @Bindable var store: StoreOf<RepositorySettingsFeature>
  @State private var selectedRemoteHostID: RemoteHost.ID?
  @State private var remoteTargetPathDraft: String = ""
  @State private var remoteTargetNameDraft: String = ""

  var body: some View {
    let baseRefOptions =
      store.branchOptions.isEmpty ? [store.defaultWorktreeBaseRef] : store.branchOptions
    let settings = $store.settings
    let worktreeBaseDirectoryPath = Binding(
      get: { settings.worktreeBaseDirectoryPath.wrappedValue ?? "" },
      set: { settings.worktreeBaseDirectoryPath.wrappedValue = $0 },
    )
    let exampleWorktreePath = store.exampleWorktreePath
    Form {
      Section {
        if store.isBranchDataLoaded {
          Picker(selection: $store.settings.worktreeBaseRef) {
            Text("Auto \(Text(store.defaultWorktreeBaseRef).foregroundStyle(.secondary))")
              .tag(String?.none)
            ForEach(baseRefOptions, id: \.self) { ref in
              Text(ref).tag(Optional(ref))
            }
          } label: {
            Text("Base branch")
            Text("New worktrees branch from this ref.")
          }
        } else {
          LabeledContent {
            ProgressView()
              .controlSize(.small)
          } label: {
            Text("Base branch")
            Text("New worktrees branch from this ref.")
          }
        }
      }
      Section {
        Picker(selection: settings.copyIgnoredOnWorktreeCreate) {
          Text("Global \(Text(store.globalCopyIgnoredOnWorktreeCreate ? "Yes" : "No").foregroundStyle(.secondary))")
            .tag(Bool?.none)
          Text("Yes").tag(Bool?.some(true))
          Text("No").tag(Bool?.some(false))
        } label: {
          Text("Copy ignored files to new worktrees")
          Text("Copies gitignored files from the main worktree.")
        }
        .disabled(store.isBareRepository)
        Picker(selection: settings.copyUntrackedOnWorktreeCreate) {
          Text("Global \(Text(store.globalCopyUntrackedOnWorktreeCreate ? "Yes" : "No").foregroundStyle(.secondary))")
            .tag(Bool?.none)
          Text("Yes").tag(Bool?.some(true))
          Text("No").tag(Bool?.some(false))
        } label: {
          Text("Copy untracked files to new worktrees")
          Text("Copies untracked files from the main worktree.")
        }
        .disabled(store.isBareRepository)
        if store.isBareRepository {
          Text("Copy flags are ignored for bare repositories.")
            .font(.footnote)
            .foregroundStyle(.tertiary)
        }
        TextField(
          text: worktreeBaseDirectoryPath,
          prompt: Text(
            SupacodePaths.worktreeBaseDirectory(
              for: store.rootURL,
              globalDefaultPath: store.globalDefaultWorktreeBaseDirectoryPath,
              repositoryOverridePath: nil
            ).path(percentEncoded: false)
          )
        ) {
          Text("Default directory").monospaced(false)
          Text("Parent path for new worktrees.").monospaced(false)
        }.monospaced()
      } header: {
        Text("Worktree")
      } footer: {
        Text("e.g., `\(exampleWorktreePath)`")
      }
      Section {
        if store.availableRemoteHosts.isEmpty {
          Text("Add a remote host in Settings → Remote Hosts first.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        } else {
          Picker(
            "Remote host",
            selection: Binding(
              get: {
                selectedRemoteHostID ?? store.availableRemoteHosts.first?.id
              },
              set: { selectedRemoteHostID = $0 }
            )
          ) {
            ForEach(store.availableRemoteHosts) { host in
              Text(host.alias).tag(Optional(host.id))
            }
          }
          TextField(
            text: $remoteTargetPathDraft,
            prompt: Text("/absolute/path/on/remote")
          ) {
            Text("Remote directory").monospaced(false)
            Text("Supacool starts remote sessions here for this repository.").monospaced(false)
          }
          .monospaced()
          TextField(
            text: $remoteTargetNameDraft,
            prompt: Text("Optional label (e.g. staging, prod)")
          ) {
            Text("Label").monospaced(false)
            Text("Shown in the New Terminal target picker.").monospaced(false)
          }
          .monospaced()
          Button("Add Remote Target", action: addRemoteTarget)
            .disabled(!canAddRemoteTarget)
        }

        if store.settings.remoteTargets.isEmpty {
          Text("No remote targets for this repository yet.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        } else {
          ForEach(store.settings.remoteTargets) { target in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              VStack(alignment: .leading, spacing: 2) {
                Text(target.displayName)
                  .font(.callout.weight(.medium))
                Text(remoteTargetSubtitle(target))
                  .font(.caption.monospaced())
                  .foregroundStyle(.secondary)
              }
              Spacer()
              Button(role: .destructive) {
                store.send(.removeRemoteTarget(id: target.id))
              } label: {
                Image(systemName: "minus.circle")
              }
              .buttonStyle(.plain)
              .help("Remove this remote target")
            }
          }
        }
      } header: {
        Text("Remote Targets")
      } footer: {
        Text("If this repo also exists remotely, New Terminal will ask whether to run locally or on one of these targets.")
      }
      Section("Pull Requests") {
        Picker(selection: settings.pullRequestMergeStrategy) {
          Text("Global \(Text(store.globalPullRequestMergeStrategy.title).foregroundStyle(.secondary))")
            .tag(PullRequestMergeStrategy?.none)
          ForEach(PullRequestMergeStrategy.allCases) { strategy in
            Text(strategy.title)
              .tag(PullRequestMergeStrategy?.some(strategy))
          }
        } label: {
          Text("Merge strategy")
          Text("Used when merging PRs from the command palette.")
        }
      }
      Section("Environment Variables") {
        ScriptEnvironmentRow(
          name: "SUPACODE_WORKTREE_PATH",
          description: "Path to the active worktree."
        )
        ScriptEnvironmentRow(
          name: "SUPACODE_ROOT_PATH",
          description: "Path to the repository root."
        )
      }
      ScriptSection(
        title: "Setup Script",
        subtitle: "Runs once after worktree creation.",
        text: settings.setupScript,
        placeholder: "claude --dangerously-skip-permissions"
      )
      ScriptSection(
        title: "Run Script",
        subtitle: "Launched on demand from the toolbar.",
        text: settings.runScript,
        placeholder: "npm run dev"
      )
      ScriptSection(
        title: "Archive Script",
        subtitle: "Runs before a worktree is archived.",
        text: settings.archiveScript,
        placeholder: "docker compose down"
      )
      ScriptSection(
        title: "Delete Script",
        subtitle: "Runs before a worktree is deleted.",
        text: settings.deleteScript,
        placeholder: "docker compose down"
      )
    }
    .formStyle(.grouped)
    .padding(.top, -20)
    .padding(.leading, -8)
    .padding(.trailing, -6)
    .task {
      store.send(.task)
      if selectedRemoteHostID == nil {
        selectedRemoteHostID = store.availableRemoteHosts.first?.id
      }
    }
  }

  private var canAddRemoteTarget: Bool {
    selectedRemoteHostID != nil
      && !remoteTargetPathDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func addRemoteTarget() {
    guard let hostID = selectedRemoteHostID ?? store.availableRemoteHosts.first?.id else { return }
    let path = remoteTargetPathDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty else { return }
    let name = remoteTargetNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    store.send(
      .addRemoteTarget(
        hostID: hostID,
        remoteWorkingDirectory: path,
        displayName: name.isEmpty ? nil : name
      )
    )
    remoteTargetPathDraft = ""
    remoteTargetNameDraft = ""
  }

  private func remoteTargetSubtitle(_ target: RepositoryRemoteTarget) -> String {
    let hostName =
      store.availableRemoteHosts.first(where: { $0.id == target.hostID })?.alias
      ?? "Unknown host"
    return "\(hostName)  \(target.remoteWorkingDirectory)"
  }
}

// MARK: - Script section.

private struct ScriptSection: View {
  let title: String
  let subtitle: String
  let text: Binding<String>
  let placeholder: String

  var body: some View {
    Section {
      TextEditor(text: text)
        .monospaced()
        .textEditorStyle(.plain)
        .autocorrectionDisabled()
        .frame(height: 112)
        .accessibilityLabel(title)
    } header: {
      Text(title)
      Text(subtitle)
    } footer: {
      Text("e.g., `\(placeholder)`")
    }
  }
}

// MARK: - Environment row.

private struct ScriptEnvironmentRow: View {
  let name: String
  let description: String

  var body: some View {
    LabeledContent {
      Button {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(name, forType: .string)
      } label: {
        Image(systemName: "doc.on.doc")
          .accessibilityLabel("Copy variable key")
      }
      .buttonStyle(.borderless)
      .help("Copy variable key.")
    } label: {
      Text(name).monospaced()
      Text(description)
    }
  }
}
