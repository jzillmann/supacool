import ComposableArchitecture
import SwiftUI

struct NotificationsSettingsView: View {
  @Bindable var store: StoreOf<SettingsFeature>

  /// Opt-in for Phase-3 PR auto-resume. Board-local behaviour, so it lives in
  /// UserDefaults (read by `BoardFeature.readAutoResumeEnabled`) rather than
  /// the persisted GlobalSettings file. Off by default.
  @AppStorage("supacool.autoResumeOnPRReturn") private var autoResumeOnPRReturn: Bool = false

  var body: some View {
    Form {
      Section {
        Toggle(
          isOn: $store.systemNotificationsEnabled
        ) {
          Text("System notifications")
        }
        .help("Show macOS system notifications")
        Toggle(
          isOn: $store.notificationSoundEnabled
        ) {
          Text("Play notification sound")
          Text(
            "Ignored when system notifications are enabled, as they play sounds"
              + " according to your settings."
          )
        }.disabled(store.systemNotificationsEnabled)
      }
      Section("Pull requests") {
        Toggle(
          isOn: $autoResumeOnPRReturn
        ) {
          Text("Auto-resume on CI failure / low Greptile score")
          Text(
            "When a PR-backed session's checks fail or Greptile flags it, hand the fix back to the"
              + " idle agent automatically (capped, then it resurfaces). Otherwise just notify."
          )
        }
        .help(
          "Only CI-failure and low-Greptile reasons are auto-resumed, and only while the agent is"
            + " idle. If its tab is gone, it resurfaces (via notification) instead."
        )
      }
      Section("Worktrees") {
        Toggle(
          isOn: $store.inAppNotificationsEnabled
        ) {
          Text("Notification badge")
          Text("Display an orange dot next to worktrees with unread notifications.")
        }
        Toggle(
          isOn: $store.moveNotifiedWorktreeToTop
        ) {
          Text("Prioritize unread worktrees")
          Text("Worktrees with unread notifications will be shown first in the list.")
        }
      }
    }
    .formStyle(.grouped)
    .padding(.top, -20)
    .padding(.leading, -8)
    .padding(.trailing, -6)

    .navigationTitle("Notifications")
  }
}
