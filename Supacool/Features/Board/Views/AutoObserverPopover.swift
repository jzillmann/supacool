import SwiftUI

/// Shared popover content for the auto-observer toggle + instructions
/// editor. Used by both the board card's sparkle button and the
/// full-screen terminal header so the two stay visually in lockstep.
struct AutoObserverPopover: View {
  let session: AgentSession
  let onToggle: () -> Void
  let onPromptChanged: (String) -> Void
  let onRunNow: () -> Void

  @State private var promptDraft: String

  init(
    session: AgentSession,
    onToggle: @escaping () -> Void,
    onPromptChanged: @escaping (String) -> Void,
    onRunNow: @escaping () -> Void
  ) {
    self.session = session
    self.onToggle = onToggle
    self.onPromptChanged = onPromptChanged
    self.onRunNow = onRunNow
    self._promptDraft = State(initialValue: session.autoObserverPrompt)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Toggle(
        "Auto-responder",
        isOn: Binding(
          get: { session.autoObserver },
          set: { _ in onToggle() }
        )
      )
      .toggleStyle(.switch)

      VStack(alignment: .leading, spacing: 4) {
        Text("Instructions (optional)")
          .font(.caption)
          .foregroundStyle(.secondary)
        TextEditor(text: $promptDraft)
          .font(.caption.monospaced())
          .frame(width: 260, height: 80)
          .scrollContentBackground(.hidden)
          .background(Color(nsColor: .controlBackgroundColor))
          .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
              .strokeBorder(.separator, lineWidth: 0.5)
          )
          .onChange(of: promptDraft) { _, newValue in
            onPromptChanged(newValue)
          }
      }

      HStack {
        Spacer()
        Button("Run now", action: onRunNow)
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
          .disabled(!session.autoObserver)
          .help("Evaluate the current screen and respond once with the instructions above")
      }
    }
    .padding(14)
  }
}
