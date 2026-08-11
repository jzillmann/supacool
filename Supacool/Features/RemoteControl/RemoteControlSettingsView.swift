import AppKit
import ComposableArchitecture
import SwiftUI

/// Settings → Remote Control. Drives the embedded MCP server: enable toggle,
/// port, live status, and the bearer token an external Claude needs to
/// connect. Lives under `Supacool/` — the remote-control plane is net-new
/// Supacool functionality.
struct RemoteControlSettingsView: View {
  @Bindable var store: StoreOf<SettingsFeature>
  @Environment(MCPControlServer.self) private var server

  @State private var token: String?
  @State private var justCopied = false

  var body: some View {
    Form {
      Section {
        Toggle(isOn: $store.remoteControlServerEnabled) {
          Text("Enable remote control server")
          Text(
            "Runs an MCP server on 127.0.0.1 so an external agent (e.g. a Claude Code "
              + "session) can list board sessions and read their terminals. Read-only."
          )
        }
        .help("Start or stop the embedded MCP server")

        LabeledContent {
          TextField(
            "4519",
            value: $store.remoteControlServerPort,
            format: .number.grouping(.never)
          )
          .textFieldStyle(.roundedBorder)
          .frame(maxWidth: 100)
          .multilineTextAlignment(.trailing)
        } label: {
          Text("Port")
          Text("The server restarts automatically when this changes.")
        }

        LabeledContent("Status") {
          statusLabel
        }
      } header: {
        Label("Server", systemImage: "antenna.radiowaves.left.and.right")
      } footer: {
        Text(
          "Listens on the loopback interface only — nothing is reachable from the network. "
            + "Every request must carry the access token below."
        )
      }

      Section {
        Toggle(isOn: $store.remoteControlServerAllowsWrites) {
          Text("Allow write access")
          Text(
            "Lets a connected agent type into terminals (send_input) and resume or rerun "
              + "sessions. Typing into a terminal is arbitrary command execution — leave this "
              + "off unless you're actively remote-controlling."
          )
        }
        .help("Expose the write tools (send_input, resume_session, rerun_session) to connected agents")
        .disabled(!store.remoteControlServerEnabled)
      } header: {
        Label("Write access", systemImage: "keyboard.badge.ellipsis")
      } footer: {
        Text("Checked on every request — no server restart needed.")
      }

      Section {
        LabeledContent("Access token") {
          HStack(spacing: 8) {
            Text(maskedToken)
              .font(.body.monospaced())
              .foregroundStyle(.secondary)
            Button("Copy") {
              copyToPasteboard(token ?? "")
            }
            .help("Copy the access token to the clipboard")
            .disabled(token == nil)
          }
        }
        Button("Regenerate Token") {
          token = try? MCPAuthToken.regenerate()
        }
        .help("Mint a new token — previously configured clients stop working until reconfigured")

        Button(justCopied ? "Copied!" : "Copy Claude Code Setup Command") {
          copyToPasteboard(claudeSetupCommand)
          justCopied = true
          Task {
            try? await Task.sleep(for: .seconds(2))
            justCopied = false
          }
        }
        .help("Copy the `claude mcp add` command that connects a Claude Code session to this server")
        .disabled(token == nil)
      } header: {
        Label("Access", systemImage: "key")
      } footer: {
        Text(
          "Token lives at ~/.supacool/mcp-token (owner-readable only). Heads-up: "
            + "`claude mcp add` echoes the token back to the terminal when run."
        )
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Remote Control")
    .task {
      token = try? MCPAuthToken.loadOrCreate()
    }
  }

  @ViewBuilder
  private var statusLabel: some View {
    switch server.status {
    case .stopped:
      Label("Stopped", systemImage: "circle")
        .foregroundStyle(.secondary)
    case .starting:
      Label("Starting…", systemImage: "circle.dotted")
        .foregroundStyle(.secondary)
    case .running(let port):
      Label("Running on 127.0.0.1:\(String(port))", systemImage: "circle.fill")
        .foregroundStyle(.green)
    case .failed(let reason):
      Label(reason, systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
    }
  }

  private var maskedToken: String {
    guard let token, token.count > 8 else { return "••••••••" }
    return "\(token.prefix(4))…\(token.suffix(4))"
  }

  private var claudeSetupCommand: String {
    "claude mcp add --transport http supacool "
      + "http://127.0.0.1:\(store.remoteControlServerPort)/mcp "
      + "--header \"Authorization: Bearer \(token ?? "<token>")\""
  }

  private func copyToPasteboard(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
  }
}
