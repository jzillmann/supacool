import ComposableArchitecture
import SwiftUI

/// Compact sheet that pops in front of the Matrix Board to capture
/// "what did you notice?" before spawning a debug agent in the
/// supacool repo.
struct DebugSessionSheetView: View {
  @Bindable var store: StoreOf<DebugSessionFeature>

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      header
      observationEditor
      if let message = store.errorMessage {
        Text(message)
          .font(.callout)
          .foregroundStyle(.red)
      }
      footer
    }
    .padding(20)
    .frame(width: 520, height: 360)
    .onExitCommand { store.send(.cancelTapped) }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Debug session")
        .font(.title3)
        .fontWeight(.semibold)
      Text(headerSubtitle)
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(2)
    }
  }

  private var headerSubtitle: String {
    let name = store.sourceSession.displayName
    return "Spawns a fresh agent in the supacool repo, primed with this "
      + "session's trace. Source: \(name)."
  }

  private var observationEditor: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("What did you notice?")
        .font(.callout)
        .fontWeight(.medium)
      TextEditor(text: $store.observation)
        .font(.body)
        .scrollContentBackground(.hidden)
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .frame(minHeight: 160)
    }
  }

  private var footer: some View {
    HStack {
      Spacer()
      Button("Cancel") { store.send(.cancelTapped) }
        .keyboardShortcut(.cancelAction)
      Button("Spawn Debug Session") { store.send(.spawnTapped) }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
    }
  }
}
