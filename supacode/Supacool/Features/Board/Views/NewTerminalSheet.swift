import ComposableArchitecture
import SwiftUI

/// The sheet for creating a new terminal session. User enters a prompt,
/// picks a repo + agent, and chooses a workspace (repo root, existing
/// worktree, existing local/remote branch, or a brand-new branch) from a
/// unified searchable combo box.
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
        if shouldShowPullRequestBanner {
          PullRequestBannerView(state: store.pullRequestLookup)
        }
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
          .disabled(isWorkspaceLockedByPR)
        workspaceField
          .disabled(isWorkspaceLockedByPR)
        if !isWorkspaceLockedByPR {
          ForEach(workspaceSuggestions, id: \.id) { suggestion in
            WorkspaceSuggestionRow(
              suggestion: suggestion,
              isSelected: suggestion.selection == store.selectedWorkspace
            )
            .contentShape(Rectangle())
            .onTapGesture {
              store.send(.workspaceSelected(suggestion.selection))
            }
          }
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
          Text(creatingStatusText)
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
    .task { store.send(.task) }
    .task(id: skillDiscoveryKey) {
      guard let skillAutocompleteAgent else {
        skillCatalog = []
        skillQuery = nil
        selectedSkillID = nil
        return
      }
      skillCatalog = await SkillCatalog.discover(for: skillAutocompleteAgent, projectRoot: selectedProjectRoot)
      reconcileSkillSelection()
    }
    .onChange(of: store.agent) { _, _ in
      skillQuery = nil
      selectedSkillID = nil
    }
    .frame(minWidth: 460, minHeight: 460)
  }

  private var promptEditor: some View {
    PromptTextEditor(
      text: $store.prompt,
      placeholder: store.agent == nil
        ? "Optional shell command to run…"
        : "Describe what the agent should do (optional)…",
      autoFocus: true,
      editorHandle: promptEditorHandle,
      skillAutocomplete: skillAutocompleteConfig,
      onSkillQuery: skillAutocompleteAgent != nil ? { handleSkillQuery($0) } : nil,
      onSkillCommand: skillAutocompleteAgent != nil ? { handleSkillCommand($0) } : nil
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
        if let skillAutocompleteAgent, let skillQuery {
          SkillAutocompletePopover(
            agent: skillAutocompleteAgent,
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

  /// Hide the banner entirely when no PR is being tracked; otherwise the
  /// prompt section stays uncluttered during normal use.
  private var shouldShowPullRequestBanner: Bool {
    switch store.pullRequestLookup {
    case .idle: return false
    case .fetching, .resolved, .failed: return true
    }
  }

  /// Lock repo + workspace fields when a PR has resolved — the PR context
  /// has already pinned them. `.failed` stays unlocked so the user can
  /// fall back to manual selection.
  private var isWorkspaceLockedByPR: Bool {
    switch store.pullRequestLookup {
    case .resolved: return true
    case .idle, .fetching, .failed: return false
    }
  }

  private var creatingStatusText: String {
    switch store.selectedWorkspace {
    case .newBranch, .existingBranch:
      return "Creating worktree…"
    case .existingWorktree, .repoRoot:
      return "Starting terminal…"
    }
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

  // MARK: - Workspace picker

  private var workspaceField: some View {
    LabeledContent {
      HStack(spacing: 6) {
        TextField(
          "Branch or new name…",
          text: $store.workspaceQuery
        )
        .textFieldStyle(.roundedBorder)
        .frame(minWidth: 200)
        if store.isSuggestingBranchName {
          ProgressView().controlSize(.small).frame(width: 16, height: 16)
        } else {
          Button {
            store.send(.suggestBranchNameTapped)
          } label: {
            Image(systemName: "wand.and.stars")
          }
          .buttonStyle(.plain)
          .foregroundStyle(
            store.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              ? .tertiary : .secondary
          )
          .disabled(store.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          .help("Generate branch name from prompt")
        }
      }
    } label: {
      Text("Workspace")
      Text(workspaceFieldFooter)
    }
  }

  private var workspaceFieldFooter: String {
    switch store.selectedWorkspace {
    case .repoRoot: return "Run at the repo root (no worktree)."
    case .existingWorktree: return "Attach to an existing worktree."
    case .existingBranch: return "Check out an existing branch in a new worktree."
    case .newBranch: return "Create a new branch from HEAD."
    }
  }

  /// Filtered list of workspace options shown below the search field.
  /// Caps at 8 rows total to keep the sheet compact.
  ///
  /// Empty query = show "Repo root" + existing worktrees only. Dumping
  /// every local and remote branch by default buries the common case
  /// (pick a registered worktree, create something new) under dozens of
  /// rows; the user opts into the branch list by typing a character.
  private var workspaceSuggestions: [WorkspaceSuggestion] {
    let query = store.workspaceQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    let lowerQuery = query.lowercased()
    let isEmptyQuery = query.isEmpty

    func matches(_ candidate: String) -> Bool {
      candidate.lowercased().contains(lowerQuery)
    }

    var results: [WorkspaceSuggestion] = []

    // 1) Repo root — always shown when query is empty; also when query matches "root" etc.
    if isEmptyQuery || matches("repo root") || matches("root") {
      results.append(
        WorkspaceSuggestion(
          id: "repoRoot",
          selection: .repoRoot,
          systemImage: "folder",
          title: "Repo root",
          subtitle: "Run at the repository root",
          kindLabel: "Directory"
        )
      )
    }

    // 2) Registered worktrees (excluding the repo root entry). Always
    //    shown — these are few and are the primary "resume where I left
    //    off" affordance.
    let worktrees: [Worktree] = {
      guard let repoID = store.selectedRepositoryID,
        let repo = store.availableRepositories[id: repoID]
      else { return [] }
      let rootPath = repo.rootURL.standardizedFileURL.path(percentEncoded: false)
      return repo.worktrees.filter { $0.id != rootPath && $0.isWorktree }
    }()

    for wt in worktrees {
      let label = wt.branch ?? wt.name
      if isEmptyQuery || matches(label) || matches(wt.name) {
        results.append(
          WorkspaceSuggestion(
            id: "wt:\(wt.id)",
            selection: .existingWorktree(id: wt.id),
            systemImage: "arrow.triangle.branch",
            title: label,
            subtitle: wt.detail.isEmpty ? "Worktree" : wt.detail,
            kindLabel: "Worktree"
          )
        )
      }
    }

    // Branches (local + remote) only show up once the user starts typing.
    if !isEmptyQuery {
      // 3) Local branches that aren't already backing a worktree.
      let branchesOnWorktrees = Set(worktrees.compactMap { $0.branch })
      for branch in store.availableLocalBranches {
        guard !branchesOnWorktrees.contains(branch) else { continue }
        if matches(branch) {
          results.append(
            WorkspaceSuggestion(
              id: "local:\(branch)",
              selection: .existingBranch(name: branch),
              systemImage: "point.3.connected.trianglepath.dotted",
              title: branch,
              subtitle: "Local branch — creates a worktree",
              kindLabel: "Local branch"
            )
          )
        }
      }

      // 4) Remote branches whose local name isn't already a local branch.
      let localSet = Set(store.availableLocalBranches)
      for remoteRef in store.availableRemoteBranches {
        let localName = NewTerminalFeature.stripRemotePrefix(remoteRef)
        guard !localSet.contains(localName) else { continue }
        guard !branchesOnWorktrees.contains(localName) else { continue }
        if matches(remoteRef) || matches(localName) {
          results.append(
            WorkspaceSuggestion(
              id: "remote:\(remoteRef)",
              selection: .existingBranch(name: localName),
              systemImage: "cloud",
              title: localName,
              subtitle: remoteRef,
              kindLabel: "Remote"
            )
          )
        }
      }

      // 5) "+ Create new" row when the query doesn't exactly match any
      //    existing option and is a valid branch name.
      let isExactMatch = results.contains { $0.title == query }
      let hasSpace = query.contains(where: \.isWhitespace)
      if !isExactMatch && !hasSpace {
        results.append(
          WorkspaceSuggestion(
            id: "new:\(query)",
            selection: .newBranch(name: query),
            systemImage: "plus.circle",
            title: "Create new branch \"\(query)\"",
            subtitle: "New branch from HEAD",
            kindLabel: "New"
          )
        )
      }
    }

    return Array(results.prefix(8))
  }

  // MARK: - Agent shortcuts & skill plumbing (unchanged)

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

  private var skillAutocompleteAgent: AgentType? {
    switch store.agent {
    case .claude?, .codex?:
      return store.agent
    case .none:
      return nil
    }
  }

  private var skillAutocompleteConfig: SkillAutocompleteConfig? {
    switch skillAutocompleteAgent {
    case .claude?:
      return SkillAutocompleteConfig(triggerCharacter: "/")
    case .codex?:
      return SkillAutocompleteConfig(triggerCharacter: "$")
    case .none:
      return nil
    }
  }

  private var skillDiscoveryKey: String {
    let repoKey = selectedProjectRoot?.path(percentEncoded: false) ?? "<none>"
    let agentKey = store.agent?.rawValue ?? "shell"
    return "\(agentKey)::\(repoKey)"
  }

  private var matchingSkills: [Skill] {
    guard let skillAutocompleteAgent, let skillQuery else { return [] }
    return SkillAutocompletePopover.orderedMatchingSkills(
      in: skillCatalog,
      queryText: skillQuery.queryText,
      for: skillAutocompleteAgent
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
    let replacement: String
    switch skillAutocompleteAgent {
    case .claude?:
      replacement = skill.isUserInvocable ? "/\(skill.name)" : skill.name
    case .codex?:
      replacement = "$\(skill.name)"
    case .none:
      replacement = skill.name
    }
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

// MARK: - Workspace suggestion row

/// One row in the workspace picker list. Clicking sends
/// `.workspaceSelected` with the backing `WorkspaceSelection`.
private struct WorkspaceSuggestion: Equatable, Identifiable {
  let id: String
  let selection: WorkspaceSelection
  let systemImage: String
  let title: String
  let subtitle: String
  let kindLabel: String
}

private struct WorkspaceSuggestionRow: View {
  let suggestion: WorkspaceSuggestion
  let isSelected: Bool

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: suggestion.systemImage)
        .frame(width: 18)
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 1) {
        Text(suggestion.title)
          .font(.callout)
          .lineLimit(1)
        Text(suggestion.subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer()
      Text(suggestion.kindLabel)
        .font(.caption2)
        .foregroundStyle(.tertiary)
      if isSelected {
        Image(systemName: "checkmark")
          .font(.caption.weight(.semibold))
          .foregroundStyle(Color.accentColor)
      }
    }
    .padding(.vertical, 2)
  }
}

// MARK: - Pull request banner

/// Status chip shown below the prompt when a GitHub PR URL has been
/// detected in the prompt. Three states: fetching (spinner), resolved
/// (PR details + branch preview), failed (warning text). Inert — all
/// interaction happens elsewhere.
private struct PullRequestBannerView: View {
  let state: PullRequestLookupState

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: iconName)
        .font(.callout)
        .foregroundStyle(iconColor)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 2) {
        Text(headline)
          .font(.callout)
          .lineLimit(2)
        if let detail {
          Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      }
      Spacer(minLength: 8)
      if case .fetching = state {
        ProgressView().controlSize(.small)
      }
    }
    .padding(.vertical, 6)
    .padding(.horizontal, 10)
    .background(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(backgroundTint)
    )
  }

  private var iconName: String {
    switch state {
    case .idle: return "link"
    case .fetching: return "link"
    case .resolved: return "checkmark.circle.fill"
    case .failed: return "exclamationmark.triangle.fill"
    }
  }

  private var iconColor: Color {
    switch state {
    case .resolved: return .accentColor
    case .failed: return .orange
    case .idle, .fetching: return .secondary
    }
  }

  private var backgroundTint: Color {
    switch state {
    case .failed: return Color.orange.opacity(0.08)
    case .resolved: return Color.accentColor.opacity(0.08)
    case .idle, .fetching: return Color.secondary.opacity(0.06)
    }
  }

  private var headline: String {
    switch state {
    case .idle: return ""
    case .fetching(let parsed):
      return "Fetching PR #\(parsed.number) from \(parsed.owner)/\(parsed.repo)…"
    case .resolved(let context):
      return "PR #\(context.parsed.number): \(context.metadata.title)"
    case .failed:
      return "Couldn't use this PR URL"
    }
  }

  private var detail: String? {
    switch state {
    case .idle, .fetching: return nil
    case .resolved(let context):
      return
        "\(context.metadata.baseRefName) ← \(context.metadata.headRefName) · "
        + "a worktree will be checked out from this branch."
    case .failed(_, let message):
      return message
    }
  }
}
