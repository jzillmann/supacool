import ComposableArchitecture
import SwiftUI

struct CodingAgentsSettingsView: View {
  let store: StoreOf<SettingsFeature>

  var body: some View {
    Form {
      AIAssistSettingsSection()
      ReferencesSettingsSection()
      Section {
        AgentInstallRow(
          installAction: { store.send(.agentHookInstallTapped(.claudeProgress)) },
          uninstallAction: { store.send(.agentHookUninstallTapped(.claudeProgress)) },
          installState: store.claudeProgressState,
          title: "Progress",
          subtitle: "Display agent activity in tab and sidebar."
        )
        AgentInstallRow(
          installAction: { store.send(.agentHookInstallTapped(.claudeNotifications)) },
          uninstallAction: { store.send(.agentHookUninstallTapped(.claudeNotifications)) },
          installState: store.claudeNotificationsState,
          title: "Notifications",
          subtitle: "Forward richer notifications to Supacool."
        )
      } header: {
        Label("Claude Code", image: "claude-code-mark")
      } footer: {
        Text("Applied to `~/.claude/settings.json`.")
      }
      Section {
        AgentInstallRow(
          installAction: { store.send(.agentHookInstallTapped(.codexProgress)) },
          uninstallAction: { store.send(.agentHookUninstallTapped(.codexProgress)) },
          installState: store.codexProgressState,
          title: "Progress",
          subtitle: "Display agent activity in tab and sidebar."
        )
        AgentInstallRow(
          installAction: { store.send(.agentHookInstallTapped(.codexNotifications)) },
          uninstallAction: { store.send(.agentHookUninstallTapped(.codexNotifications)) },
          installState: store.codexNotificationsState,
          title: "Notifications",
          subtitle: "Forward richer notifications to Supacool."
        )
      } header: {
        Label("Codex", image: "codex-mark")
      } footer: {
        Text("Applied to `~/.codex/hooks.json`.")
      }
    }
    .formStyle(.grouped)
    .padding(.top, -20)
    .padding(.leading, -8)
    .padding(.trailing, -6)
    .navigationTitle("Coding Agents")
  }
}

// MARK: - AI Assist

private struct AIAssistSettingsSection: View {
  @AppStorage("supacool.inference.mode") private var mode: String = "claudeCLI"
  @AppStorage("supacool.inference.cliModel") private var cliModel: String = ""
  @AppStorage("supacool.inference.apiModel") private var apiModel: String = "claude-sonnet-4-6"
  @AppStorage("supacool.inference.apiKey") private var apiKey: String = ""

  var body: some View {
    Section {
      Picker("Mode", selection: $mode) {
        Text("Claude CLI (Max subscription)").tag("claudeCLI")
        Text("Anthropic API").tag("anthropicAPI")
      }
      .pickerStyle(.menu)

      if mode == "claudeCLI" {
        LabeledContent("Model") {
          TextField("Default", text: $cliModel)
            .frame(maxWidth: 200)
        }
      } else {
        LabeledContent("API Key") {
          SecureField("sk-ant-…", text: $apiKey)
            .frame(maxWidth: 200)
        }
        LabeledContent("Model") {
          TextField("claude-sonnet-4-6", text: $apiModel)
            .frame(maxWidth: 200)
        }
      }
    } header: {
      Label("AI Assist", systemImage: "wand.and.stars")
    } footer: {
      if mode == "claudeCLI" {
        Text("Uses your Claude Max subscription via the `claude` CLI. No API credits needed.")
      } else {
        Text("Uses the Anthropic API directly. Charged to your API account.")
      }
    }
  }
}

// MARK: - References

/// Supacool scans session transcripts for Linear tickets and GitHub PR
/// URLs and surfaces them as clickable chips on board cards. This section
/// configures the link destinations and optional prefix filter.
private struct ReferencesSettingsSection: View {
  @AppStorage("supacool.references.linearOrg") private var linearOrg: String = ""
  @AppStorage("supacool.references.ticketPrefixes") private var ticketPrefixes: String = ""

  var body: some View {
    Section {
      LabeledContent {
        TextField("your-org", text: $linearOrg)
          .textFieldStyle(.roundedBorder)
          .frame(maxWidth: 240)
      } label: {
        Text("Linear org slug")
        Text("Used to build ticket URLs like `linear.app/<slug>/issue/<id>`. Leave empty if you don't use Linear — chips still render but aren't clickable.")
      }
      LabeledContent {
        TextField("CEN, FOO", text: $ticketPrefixes)
          .textFieldStyle(.roundedBorder)
          .frame(maxWidth: 240)
      } label: {
        Text("Ticket prefix allowlist")
        Text("Comma-separated list of team keys (e.g. `CEN`). Empty = any uppercase prefix matches, which can pick up noise like `HTTP-200`.")
      }
    } header: {
      Label("References", systemImage: "link")
    } footer: {
      Text("Parsed from Claude Code session transcripts. Codex sessions fall back to scanning just the initial prompt.")
    }
  }
}

private struct AgentInstallRow: View {
  let installAction: () -> Void
  let uninstallAction: () -> Void
  let installState: AgentHooksInstallState
  let title: String
  let subtitle: String

  var body: some View {
    LabeledContent {
      switch installState {
      case .checking:
        ProgressView()
      case .installed:
        ControlGroup {
          Label("Installed", systemImage: "checkmark")
          Button("Uninstall", role: .destructive, action: uninstallAction)
        }
      case .notInstalled, .failed:
        Button("Install", action: installAction)
      case .installing:
        Button("Installing\u{2026}") {}
          .disabled(true)
      case .uninstalling:
        Button("Uninstalling\u{2026}") {}
          .disabled(true)
      }
    } label: {
      Text(title)
      Text(subtitle)
      if let message = installState.errorMessage {
        Text(message).foregroundStyle(.red)
      }
    }
  }
}
