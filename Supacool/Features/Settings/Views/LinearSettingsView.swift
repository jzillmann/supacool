import ComposableArchitecture
import SwiftUI

/// Top-level Linear settings tab. Holds the API key (used to resolve
/// ticket titles in the New Terminal sheet) plus the link-rendering
/// knobs (org slug, ticket-prefix allowlist) that drive reference
/// chips on board cards.
///
/// Lives under `Supacool/` because Linear integration is net-new
/// Supacool functionality, not an upstream-supacode concept.
struct LinearSettingsView: View {
  @AppStorage("supacool.linear.apiKey") private var linearAPIKey: String = ""
  @AppStorage("supacool.references.linearOrg") private var linearOrg: String = ""
  @AppStorage("supacool.references.ticketPrefixes") private var ticketPrefixes: String = ""

  var body: some View {
    Form {
      Section {
        LabeledContent {
          SecureField("lin_api_…", text: $linearAPIKey)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 280)
        } label: {
          Text("API key")
          Text(
            "Optional. When set, typing a ticket id in the New Terminal prompt "
              + "(e.g. `Fix CEN-6690`) fetches the issue title and uses it for the "
              + "suggested branch name and card title."
          )
        }
        Link(
          "Generate a personal API key",
          destination: URL(string: "https://linear.app/settings/api")!
        )
        .controlSize(.small)
      } header: {
        Label("Authentication", systemImage: "key")
      } footer: {
        Text("Stored locally in your user defaults. Never transmitted anywhere except `api.linear.app`.")
      }

      Section {
        LabeledContent {
          TextField("your-org", text: $linearOrg)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 280)
        } label: {
          Text("Org slug")
          Text(
            "Optional. When empty, ticket chips open the Linear desktop app by issue ID. "
              + "Set this to build exact URLs like `linear.app/<slug>/issue/<id>`."
          )
        }
        LabeledContent {
          TextField("CEN, FOO", text: $ticketPrefixes)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 280)
        } label: {
          Text("Ticket prefix allowlist")
          Text(
            "Comma-separated list of team keys (e.g. `CEN`). Empty = any uppercase prefix matches, "
              + "which can pick up noise like `HTTP-200`."
          )
        }
      } header: {
        Label("References", systemImage: "link")
      } footer: {
        Text("Ticket chips are parsed from Claude Code session transcripts. Codex sessions fall back to scanning just the initial prompt.")
      }
    }
    .formStyle(.grouped)
    .padding(.top, -20)
    .padding(.leading, -8)
    .padding(.trailing, -6)
    .navigationTitle("Linear")
  }
}
