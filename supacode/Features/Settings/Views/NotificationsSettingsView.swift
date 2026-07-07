import ComposableArchitecture
import SwiftUI

struct NotificationsSettingsView: View {
  @Bindable var store: StoreOf<SettingsFeature>

  /// Opt-in for Phase-3 PR auto-resume. Board-local behaviour, so it lives in
  /// UserDefaults (read by `AutoResumeSettings.load()`) rather than the
  /// persisted GlobalSettings file. Off by default.
  @AppStorage(AutoResumeSettings.masterDefaultsKey) private var autoResumeOnPRReturn: Bool = false

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
          Text("Auto-resume on PR return")
          Text(
            "When a PR-backed session bounces back for a mechanical reason, hand the fix back to"
              + " the idle agent automatically (capped, then it resurfaces). Otherwise just notify."
          )
        }
        .help(
          "Only mechanical reasons are auto-resumed, and only while the agent is idle. If its tab"
            + " is gone, it resurfaces (via notification) instead. When several reasons hit at"
            + " once, their texts are combined into one instruction."
        )
        if autoResumeOnPRReturn {
          ForEach(AutoResumeSettings.Case.allCases) { kind in
            AutoResumeCaseEditor(kind: kind)
          }
        }
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

/// One auto-resume case: an enable toggle plus the editable instruction
/// template injected into the agent when that condition brings the PR back.
/// Reads/writes the same UserDefaults keys `AutoResumeSettings.load()` reads.
private struct AutoResumeCaseEditor: View {
  let kind: AutoResumeSettings.Case
  @AppStorage private var enabled: Bool
  @AppStorage private var template: String

  init(kind: AutoResumeSettings.Case) {
    self.kind = kind
    _enabled = AppStorage(wrappedValue: true, kind.enabledDefaultsKey)
    _template = AppStorage(wrappedValue: kind.defaultTemplate, kind.templateDefaultsKey)
  }

  var body: some View {
    Toggle(isOn: $enabled) {
      Text(kind.title)
    }
    .help("Auto-resume the session's agent when this brings the PR back into your court")
    if enabled {
      VStack(alignment: .leading, spacing: 4) {
        TextEditor(text: $template)
          .font(.body.monospaced())
          .frame(minHeight: 56)
        if let hint = kind.placeholderHint {
          Text(hint)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        if template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          || template != kind.defaultTemplate
        {
          Button("Reset to default") {
            template = kind.defaultTemplate
          }
          .buttonStyle(.link)
          .font(.caption)
          .help("Restore this case's built-in instruction text")
        }
      }
    }
  }
}
