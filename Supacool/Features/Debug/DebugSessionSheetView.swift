import ComposableArchitecture
import SwiftUI

/// Compact sheet that pops in front of the Matrix Board to capture
/// "what did you notice?" before spawning a debug agent in the
/// supacool repo.
///
/// Two structurally different modes:
///   - registered: header + observation editor + Cancel / Spawn
///   - missing:    header + explanation + Open repo picker / Close
struct DebugSessionSheetView: View {
  @Bindable var store: StoreOf<DebugSessionFeature>

  var body: some View {
    Group {
      if store.isSupacoolRepoRegistered {
        registeredBody
      } else {
        missingRepoBody
      }
    }
    .padding(20)
    .frame(width: 520)
    .frame(minHeight: 200, idealHeight: 360, maxHeight: 360)
    .onExitCommand { store.send(.cancelTapped) }
  }

  // MARK: Header (shared)

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

  // MARK: Registered (happy path)

  private var registeredBody: some View {
    VStack(alignment: .leading, spacing: 16) {
      header
      agentPicker
      observationEditor
      if let message = store.errorMessage {
        Text(message)
          .font(.callout)
          .foregroundStyle(.red)
      }
      registeredFooter
    }
  }

  private var agentPicker: some View {
    HStack(spacing: 10) {
      Text("Agent")
        .font(.callout)
        .fontWeight(.medium)
      Picker(selection: $store.agent) {
        ForEach(AgentRegistry.allAgents) { agent in
          Text(agent.displayName).tag(agent)
        }
      } label: {
        EmptyView()
      }
      .labelsHidden()
      .pickerStyle(.segmented)
      .fixedSize()
      Spacer(minLength: 0)
    }
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

  private var registeredFooter: some View {
    HStack {
      Spacer()
      Button("Cancel") { store.send(.cancelTapped) }
        .keyboardShortcut(.cancelAction)
      Button("Spawn Debug Session") { store.send(.spawnTapped) }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
    }
  }

  // MARK: Missing repo

  private var missingRepoBody: some View {
    VStack(alignment: .leading, spacing: 16) {
      header
      missingRepoExplanation
      missingRepoFooter
    }
  }

  private var missingRepoExplanation: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.title2)
        .foregroundStyle(.orange)
      VStack(alignment: .leading, spacing: 6) {
        Text("Supacool repo isn't registered")
          .font(.headline)
        Text(
          "Debug sessions run inside the Supacool source tree so the "
            + "agent can read the trace AND patch the code that produced "
            + "it. Register your local clone of supacool first — pick the "
            + "folder containing supacool.xcodeproj."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color.orange.opacity(0.10))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
    )
  }

  private var missingRepoFooter: some View {
    HStack {
      Spacer()
      Button("Close") { store.send(.cancelTapped) }
        .keyboardShortcut(.cancelAction)
      Button("Choose supacool folder…") {
        store.send(.registerSupacoolTapped)
      }
      .buttonStyle(.borderedProminent)
      .keyboardShortcut(.defaultAction)
    }
  }
}
