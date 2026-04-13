import ComposableArchitecture
import SwiftUI

/// The sheet for creating a new terminal session. User enters a prompt,
/// picks a repo + agent, optionally enables worktree mode with a branch
/// name, and hits Create.
struct NewTerminalSheet: View {
  @Bindable var store: StoreOf<NewTerminalFeature>

  var body: some View {
    Form {
      Section {
        promptEditor
      } header: {
        Text("New Terminal")
        Text("Start an interactive \(store.agent.displayName) session with this prompt.")
      }
      .headerProminence(.increased)

      Section {
        agentPicker
        repoPicker
        worktreeToggle
        if store.useWorktree {
          TextField("Branch name", text: $store.branchName)
            .onSubmit { store.send(.createButtonTapped) }
        }
      } footer: {
        if let message = store.validationMessage, !message.isEmpty {
          Text(message).foregroundStyle(.red)
        }
      }
    }
    .formStyle(.grouped)
    .scrollBounceBehavior(.basedOnSize)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      HStack {
        if store.isCreating {
          ProgressView().controlSize(.small)
          Text(store.useWorktree ? "Creating worktree…" : "Starting terminal…")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Cancel") { store.send(.cancelButtonTapped) }
          .keyboardShortcut(.cancelAction)
          .disabled(store.isCreating)
        Button("Create") { store.send(.createButtonTapped) }
          .keyboardShortcut(.defaultAction)
          .disabled(store.isCreating)
      }
      .padding(.horizontal, 20)
      .padding(.bottom, 20)
    }
    .background {
      agentShortcuts
    }
    .frame(minWidth: 460, minHeight: 420)
  }

  private var promptEditor: some View {
    // PromptTextEditor has a KNOWN textContainerInset of (5, 6). The
    // placeholder below uses those exact numbers for padding so the
    // cursor lines up with the first glyph. Auto-focuses on appear.
    ZStack(alignment: .topLeading) {
      PromptTextEditor(text: $store.prompt, autoFocus: true)
        .frame(minHeight: 100, maxHeight: 220)
      if store.prompt.isEmpty {
        Text("Describe what the agent should do…")
          .font(.body)
          .foregroundStyle(.tertiary)
          .padding(.leading, PromptTextEditor.inset.width)
          .padding(.top, PromptTextEditor.inset.height)
          .allowsHitTesting(false)
      }
    }
    .background(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(Color(nsColor: .textBackgroundColor).opacity(0.4))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
    )
  }

  private var agentPicker: some View {
    Picker(selection: $store.agent) {
      ForEach(AgentType.allCases) { agent in
        Text(agent.displayName).tag(agent)
      }
    } label: {
      Text("Agent")
      Text("Which CLI spawns for this session.")
    }
    .pickerStyle(.segmented)
  }

  private var repoPicker: some View {
    Picker(selection: $store.selectedRepositoryID) {
      if store.availableRepositories.isEmpty {
        Text("No repositories registered").tag(Optional<Repository.ID>.none)
      } else {
        ForEach(store.availableRepositories) { repo in
          Text(repo.name).tag(Optional(repo.id))
        }
      }
    } label: {
      Text("Repository")
      Text("Terminal runs inside this repo's working directory.")
    }
    .disabled(store.availableRepositories.count <= 1)
  }

  private var worktreeToggle: some View {
    Toggle(isOn: $store.useWorktree) {
      Text("Create worktree")
      Text("Isolate the agent's changes on a new git worktree branched from HEAD.")
    }
  }

  private var agentShortcuts: some View {
    Group {
      Button("") { store.agent = .claude }
        .keyboardShortcut("1", modifiers: .command)
        .hidden()
      Button("") { store.agent = .codex }
        .keyboardShortcut("2", modifiers: .command)
        .hidden()
    }
  }
}
