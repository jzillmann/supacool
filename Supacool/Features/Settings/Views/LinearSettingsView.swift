import ComposableArchitecture
import SwiftUI

/// Top-level Linear settings tab. Holds the API key (used to resolve
/// ticket titles in the New Terminal sheet) plus the org slug that drives
/// reference-chip URLs on board cards.
///
/// Team keys are configured **per repository** (Settings → <repository> →
/// Linear): they scope both the recent-ticket import and transcript chip
/// parsing for that repo. There is no global team-key setting.
///
/// Lives under `Supacool/` because Linear integration is net-new
/// Supacool functionality, not an upstream-supacode concept.
struct LinearSettingsView: View {
  @AppStorage("supacool.linear.apiKey") private var linearAPIKey: String = ""
  @AppStorage("supacool.references.linearOrg") private var linearOrg: String = ""

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
      } header: {
        Label("References", systemImage: "link")
      } footer: {
        Text(
          "Ticket chips are parsed from Claude Code session transcripts (Codex sessions fall back to the "
            + "initial prompt). Team keys that scope which tickets become chips — and the Linear Inbox's "
            + "recent-ticket import — are set per repository under Settings → <repository> → Linear."
        )
      }
    }
    .formStyle(.grouped)
    .padding(.top, -20)
    .padding(.leading, -8)
    .padding(.trailing, -6)
    .navigationTitle("Linear")
  }
}
