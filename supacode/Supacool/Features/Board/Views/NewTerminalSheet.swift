import ComposableArchitecture
import SwiftUI

/// The sheet for creating a new terminal session. User enters a prompt,
/// picks a repo + agent, optionally enables worktree mode with a branch
/// name, and hits Create.
struct NewTerminalSheet: View {
  @Bindable var store: StoreOf<NewTerminalFeature>
  @AppStorage("supacool.bypassPermissions") private var bypassPermissions: Bool = true

  var body: some View {
    Form {
      Section {
        promptEditor
      } header: {
        Text("New Terminal")
        Text(headerSubtitle)
      }
      .headerProminence(.increased)

      Section {
        agentPicker
        if store.agent != nil {
          bypassPermissionsToggle
        }
        repoPicker
        worktreeModePicker
        switch store.worktreeMode {
        case .none:
          EmptyView()
        case .newBranch:
          TextField("Branch name", text: $store.branchName)
            .onSubmit { store.send(.createButtonTapped) }
        case .existing:
          existingWorktreePicker
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
          Text(store.worktreeMode == .newBranch ? "Creating worktree…" : "Starting terminal…")
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
    PromptTextEditor(
      text: $store.prompt,
      placeholder: store.agent == nil
        ? "Optional shell command to run…"
        : "Describe what the agent should do (optional)…",
      autoFocus: true
    )
    .frame(minHeight: 100, maxHeight: 220)
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
      Text("Shell").tag(Optional<AgentType>.none)
      ForEach(AgentType.allCases) { agent in
        Text(agent.displayName).tag(Optional(agent))
      }
    } label: {
      Text("Agent")
      Text("Pick a CLI to spawn, or Shell for a raw terminal.")
    }
    .pickerStyle(.segmented)
  }

  private var headerSubtitle: String {
    if let agent = store.agent {
      return "Start an interactive \(agent.displayName) session with this prompt."
    }
    return "Start a raw terminal session. The prompt (if any) runs as a shell command."
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

  private var bypassPermissionsToggle: some View {
    Toggle(isOn: $bypassPermissions) {
      Text("Skip permission prompts")
      Text("Launch the agent with \(store.agent?.bypassPermissionsFlag ?? "--"). Lets it act without confirming each tool use.")
    }
  }

  private var worktreeModePicker: some View {
    Picker(selection: $store.worktreeMode) {
      ForEach(WorktreeMode.allCases) { mode in
        Text(mode.label).tag(mode)
      }
    } label: {
      Text("Worktree")
      Text(worktreeModeFooter)
    }
    .pickerStyle(.segmented)
    .disabled(!existingWorktreesAvailable && store.worktreeMode == .none)
    .onChange(of: store.worktreeMode) { _, newMode in
      // Default to the first non-root worktree on mode-switch so the
      // picker isn't empty on first paint.
      if newMode == .existing, store.existingWorktreeID == nil {
        store.existingWorktreeID = firstExistingWorktreeID
      }
    }
    .onChange(of: store.selectedRepositoryID) { _, _ in
      // Repo changed — drop any stale existing-worktree pick.
      store.existingWorktreeID = firstExistingWorktreeID
    }
  }

  private var existingWorktreePicker: some View {
    Picker(selection: $store.existingWorktreeID) {
      if availableExistingWorktrees.isEmpty {
        Text("No worktrees registered").tag(Optional<String>.none)
      } else {
        ForEach(availableExistingWorktrees, id: \.id) { worktree in
          Text(worktreeDisplayName(worktree)).tag(Optional(worktree.id))
        }
      }
    } label: {
      Text("Worktree")
      Text("Run inside an already-registered worktree of this repo.")
    }
    .disabled(availableExistingWorktrees.isEmpty)
  }

  private var worktreeModeFooter: String {
    switch store.worktreeMode {
    case .none: "Run at the repo root."
    case .newBranch: "Create a fresh worktree branched from HEAD."
    case .existing: "Attach to an already-registered worktree."
    }
  }

  /// Non-root worktrees of the selected repo, available for the Existing
  /// picker. We exclude the root directory-mode entry because that's
  /// already covered by `.none`.
  private var availableExistingWorktrees: [Worktree] {
    guard let repoID = store.selectedRepositoryID,
      let repo = store.availableRepositories[id: repoID]
    else { return [] }
    let rootPath = repo.rootURL.standardizedFileURL.path(percentEncoded: false)
    return repo.worktrees.filter { $0.id != rootPath && $0.isWorktree }
  }

  private var existingWorktreesAvailable: Bool {
    !availableExistingWorktrees.isEmpty
  }

  private var firstExistingWorktreeID: String? {
    availableExistingWorktrees.first?.id
  }

  private func worktreeDisplayName(_ worktree: Worktree) -> String {
    worktree.branch ?? worktree.name
  }

  private var agentShortcuts: some View {
    Group {
      Button("") { store.agent = nil }
        .keyboardShortcut("0", modifiers: .command)
        .hidden()
      Button("") { store.agent = .claude }
        .keyboardShortcut("1", modifiers: .command)
        .hidden()
      Button("") { store.agent = .codex }
        .keyboardShortcut("2", modifiers: .command)
        .hidden()
    }
  }
}
