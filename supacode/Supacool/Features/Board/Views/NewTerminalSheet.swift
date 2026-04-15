import ComposableArchitecture
import SwiftUI

/// The sheet for creating a new terminal session. User enters a prompt,
/// picks a repo + agent, optionally enables worktree mode with a branch
/// name, and hits Create.
struct NewTerminalSheet: View {
  @Bindable var store: StoreOf<NewTerminalFeature>
  @AppStorage("supacool.bypassPermissions") private var bypassPermissions: Bool = true
  @State private var skillCatalog: [Skill] = []
  @State private var skillQuery: SkillQuery?
  @State private var selectedSkillID: Skill.ID?
  @State private var promptEditorHandle = PromptTextEditorHandle()

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
    .task(id: skillDiscoveryKey) {
      guard store.agent == .claude else {
        skillCatalog = []
        skillQuery = nil
        selectedSkillID = nil
        return
      }
      skillCatalog = await SkillCatalog.discover(projectRoot: selectedProjectRoot)
      reconcileSkillSelection()
    }
    .onChange(of: store.agent) { _, newAgent in
      guard newAgent != .claude else { return }
      skillQuery = nil
      selectedSkillID = nil
    }
    .frame(minWidth: 460, minHeight: 420)
  }

  private var promptEditor: some View {
    PromptTextEditor(
      text: $store.prompt,
      placeholder: store.agent == nil
        ? "Optional shell command to run…"
        : "Describe what the agent should do (optional)…",
      autoFocus: true,
      editorHandle: promptEditorHandle,
      onSkillQuery: store.agent == .claude ? { handleSkillQuery($0) } : nil,
      onSkillCommand: store.agent == .claude ? { handleSkillCommand($0) } : nil
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
    .overlay(alignment: .topLeading) {
      GeometryReader { geometry in
        if store.agent == .claude, let skillQuery {
          SkillAutocompletePopover(
            queryText: skillQuery.queryText,
            skills: skillCatalog,
            selectedSkillID: selectedSkillID,
            onSelect: { commitSkill($0) }
          )
          .offset(
            x: popupX(for: skillQuery, availableWidth: geometry.size.width),
            y: popupY(for: skillQuery, availableHeight: geometry.size.height)
          )
        }
      }
    }
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

  private var selectedProjectRoot: URL? {
    guard let repoID = store.selectedRepositoryID else { return nil }
    return store.availableRepositories[id: repoID]?.rootURL.standardizedFileURL
  }

  private var skillDiscoveryKey: String {
    let repoKey = selectedProjectRoot?.path(percentEncoded: false) ?? "<none>"
    let agentKey = store.agent?.rawValue ?? "shell"
    return "\(agentKey)::\(repoKey)"
  }

  private var matchingSkills: [Skill] {
    guard let skillQuery else { return [] }
    return SkillAutocompletePopover.orderedMatchingSkills(
      in: skillCatalog,
      queryText: skillQuery.queryText
    )
  }

  private func handleSkillQuery(_ query: SkillQuery?) {
    skillQuery = query
    reconcileSkillSelection()
  }

  private func handleSkillCommand(_ command: SkillAutocompleteCommand) {
    guard skillQuery != nil else { return }
    switch command {
    case .moveSelection(let delta):
      moveSkillSelection(by: delta)
    case .commitSelection:
      commitSelectedSkill()
    case .dismiss:
      skillQuery = nil
      selectedSkillID = nil
    }
  }

  private func reconcileSkillSelection() {
    let skills = matchingSkills
    guard !skills.isEmpty else {
      selectedSkillID = nil
      return
    }
    if let selectedSkillID, skills.contains(where: { $0.id == selectedSkillID }) {
      return
    }
    selectedSkillID = skills.first?.id
  }

  private func moveSkillSelection(by delta: Int) {
    let skills = matchingSkills
    guard !skills.isEmpty else { return }

    let currentIndex = selectedSkillID.flatMap { id in
      skills.firstIndex(where: { $0.id == id })
    } ?? -1
    let nextIndex: Int
    if currentIndex < 0 {
      nextIndex = delta < 0 ? skills.count - 1 : 0
    } else {
      nextIndex = (currentIndex + delta + skills.count) % skills.count
    }
    selectedSkillID = skills[nextIndex].id
  }

  private func commitSelectedSkill() {
    let skills = matchingSkills
    guard !skills.isEmpty else { return }
    if let selectedSkillID,
      let selected = skills.first(where: { $0.id == selectedSkillID })
    {
      commitSkill(selected)
      return
    }
    if let first = skills.first {
      commitSkill(first)
    }
  }

  private func commitSkill(_ skill: Skill) {
    let replacement = skill.isUserInvocable ? "/\(skill.name)" : skill.name
    promptEditorHandle.commitSkill(replacement)
    skillQuery = nil
    selectedSkillID = nil
  }

  private func popupX(for query: SkillQuery, availableWidth: CGFloat) -> CGFloat {
    let preferredWidth: CGFloat = 360
    let maxX = max(availableWidth - preferredWidth - 8, 0)
    return min(max(query.caretRect.minX, 0), maxX)
  }

  private func popupY(for query: SkillQuery, availableHeight: CGFloat) -> CGFloat {
    let preferredY = query.caretRect.maxY + 8
    return min(max(preferredY, 0), max(availableHeight - 8, 0))
  }
}
