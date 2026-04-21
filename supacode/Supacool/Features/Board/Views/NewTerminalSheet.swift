import ComposableArchitecture
import SwiftUI

/// The sheet for creating a new terminal session. User enters a prompt,
/// picks a repo + agent, and chooses a workspace (repo root, existing
/// worktree, existing local/remote branch, or a brand-new branch) from a
/// unified searchable combo box.
/// SwiftUI `Form` sections paint their card backgrounds in render order,
/// so an overlay attached to the prompt editor (Section 1) gets painted
/// over by the Agent / Repo / Workspace card (Section 2). The fix:
/// publish the prompt editor's bounds via an anchor preference and
/// render the autocomplete popover from `.overlayPreferenceValue` at
/// the sheet root, where it can hang freely below the editor.
private struct PromptEditorAnchorKey: PreferenceKey {
  static let defaultValue: Anchor<CGRect>? = nil
  static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
    value = nextValue() ?? value
  }
}

struct NewTerminalSheet: View {
  @Bindable var store: StoreOf<NewTerminalFeature>
  @AppStorage("supacool.bypassPermissions") private var bypassPermissions: Bool = true
  @State private var skillCatalog: [Skill] = []
  @State private var skillQuery: SkillQuery?
  @State private var selectedSkillID: Skill.ID?
  @State private var promptEditorHandle = PromptTextEditorHandle()
  /// Restored into `workspaceQuery` when the user re-enables "New
  /// worktree" after toggling it off — keeps a typed branch name from
  /// disappearing on a flip-flop.
  @State private var lastBranchQuery: String = ""
  /// Persists the disclosure state of the Advanced section so it stays
  /// open across re-renders within a single sheet presentation.
  @State private var isAdvancedExpanded: Bool = false

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
        destinationPicker
        if store.destination.isRemote {
          remoteWorkingDirectoryField
        } else {
          repositoryRow
            .disabled(isWorkspaceLockedByPR)
          worktreeToggle
            .disabled(isWorkspaceLockedByPR)
          if isUsingWorktree, !isWorkspaceLockedByPR {
            workspaceField
            ForEach(workspaceSuggestions, id: \.id) { suggestion in
              WorkspaceSuggestionRow(
                suggestion: suggestion,
                isSelected: suggestion.selection == store.selectedWorkspace
              )
              .contentShape(Rectangle())
              .onTapGesture {
                store.send(.workspaceSelected(suggestion.selection))
              }
              // The suggestion list is part of the Workspace row, not its
              // own section — drop the auto-rendered divider above so the
              // field + matches read as one unit.
              .listRowSeparator(.hidden, edges: .top)
            }
          }
        }
        if store.agent != nil {
          DisclosureGroup("Advanced", isExpanded: $isAdvancedExpanded) {
            bypassPermissionsToggle
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
    .overlayPreferenceValue(PromptEditorAnchorKey.self) { anchor in
      skillAutocompleteFloat(anchor: anchor)
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
      onSkillCommand: skillAutocompleteAgent != nil ? { handleSkillCommand($0) } : nil,
      skillValidator: skillNameValidator,
      onCancelRequested: { store.send(.cancelButtonTapped) }
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
    // Publish the prompt editor's bounds so the sheet root can draw
    // the autocomplete popover outside this Form Section's clip.
    .anchorPreference(key: PromptEditorAnchorKey.self, value: .bounds) { $0 }
  }

  /// Floating skill autocomplete popover, drawn from the sheet root via
  /// `.overlayPreferenceValue`. Resolves the prompt editor's bounds in
  /// the overlay's local coordinate space using `proxy[anchor]`, then
  /// offsets the popover to sit just below the caret.
  @ViewBuilder
  private func skillAutocompleteFloat(anchor: Anchor<CGRect>?) -> some View {
    if let skillAutocompleteAgent, let skillQuery, let anchor {
      GeometryReader { proxy in
        let editorRect = proxy[anchor]
        SkillAutocompletePopover(
          agent: skillAutocompleteAgent,
          queryText: skillQuery.queryText,
          skills: skillCatalog,
          selectedSkillID: selectedSkillID,
          onSelect: { commitSkill($0) }
        )
        .offset(
          x: floatingPopupX(for: skillQuery, editorRect: editorRect),
          y: floatingPopupY(for: skillQuery, editorRect: editorRect)
        )
      }
      .allowsHitTesting(true)
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

  /// Repository selector. With a single registered repo the picker
  /// Segmented picker that flips between a local repo-backed session and
  /// any of the configured remote SSH hosts. Rendered at the top of the
  /// agent section so the rest of the form (repo/worktree OR remote path)
  /// adapts underneath.
  @ViewBuilder
  private var destinationPicker: some View {
    // With no imported remote hosts the picker adds nothing — keep the
    // local-only sheet visually clean.
    if store.availableRemoteHosts.isEmpty {
      EmptyView()
    } else {
      Picker(selection: destinationBinding) {
        Text("Local").tag(NewTerminalFeature.Destination.local)
        ForEach(store.availableRemoteHosts) { host in
          Text(host.alias).tag(NewTerminalFeature.Destination.remote(hostID: host.id))
        }
      } label: {
        Text("Destination")
        Text("Run locally, or SSH into one of the imported remote hosts.")
      }
      .pickerStyle(.menu)
    }
  }

  /// Absolute path on the remote host where tmux will start. Suggestions
  /// pull from `availableRemoteWorkspaces` (workspaces you've spawned
  /// into before) plus the host's configured default root, if any.
  @ViewBuilder
  private var remoteWorkingDirectoryField: some View {
    LabeledContent {
      VStack(alignment: .trailing, spacing: 6) {
        TextField(
          remoteDefaultRoot ?? "/absolute/path/on/remote",
          text: $store.remoteWorkingDirectoryDraft
        )
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: 340)
        if !remoteWorkspaceSuggestions.isEmpty {
          VStack(alignment: .leading, spacing: 2) {
            ForEach(remoteWorkspaceSuggestions, id: \.id) { ws in
              Button {
                store.remoteWorkingDirectoryDraft = ws.remoteWorkingDirectory
              } label: {
                HStack {
                  Image(systemName: "clock.arrow.circlepath")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                  Text(ws.remoteWorkingDirectory)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                  Spacer()
                }
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
            }
          }
          .padding(.top, 4)
        }
      }
    } label: {
      Text("Remote directory")
      Text("Absolute path on the host — tmux starts here.")
    }
  }

  /// Two-way binding that dispatches `destinationChanged` on set so the
  /// reducer can clear stale validation state.
  private var destinationBinding: Binding<NewTerminalFeature.Destination> {
    Binding(
      get: { store.destination },
      set: { store.send(.destinationChanged($0)) }
    )
  }

  /// Workspaces previously used for whichever remote host is selected.
  /// Empty list → no inline suggestions, the user types a fresh path.
  private var remoteWorkspaceSuggestions: [RemoteWorkspace] {
    guard case .remote(let hostID) = store.destination else { return [] }
    return store.availableRemoteWorkspaces.filter { $0.hostID == hostID }
  }

  /// The chosen host's default remote workspace root, shown as a
  /// placeholder in the path field so users know the expected shape.
  private var remoteDefaultRoot: String? {
    guard case .remote(let hostID) = store.destination,
      let host = store.availableRemoteHosts.first(where: { $0.id == hostID })
    else { return nil }
    return host.overrides.defaultRemoteWorkspaceRoot
  }

  /// would just show one immutable choice — collapse it to a static
  /// label to cut a visual row from the sheet. Multi-repo users still
  /// see the full picker.
  @ViewBuilder
  private var repositoryRow: some View {
    if store.availableRepositories.count <= 1 {
      LabeledContent {
        Text(store.availableRepositories.first?.name ?? "No repositories registered")
          .foregroundStyle(.secondary)
      } label: {
        Text("Repository")
      }
    } else {
      Picker(selection: $store.selectedRepositoryID) {
        ForEach(store.availableRepositories) { repo in
          Text(repo.name).tag(Optional(repo.id))
        }
      } label: {
        Text("Repository")
        Text("Terminal runs inside this repo's working directory.")
      }
    }
  }

  /// Yes/no gate for the worktree workflow. OFF runs the agent at the
  /// repo root; ON reveals the branch field below where the user picks
  /// (or creates) a branch to check out into a fresh worktree.
  private var worktreeToggle: some View {
    Toggle(isOn: useWorktreeBinding) {
      Text("New worktree")
      Text("Off = run at repo root. On = check out a branch in a worktree.")
    }
  }

  /// True when the current selection isn't `.repoRoot` — i.e. the user
  /// wants a worktree.
  private var isUsingWorktree: Bool {
    if case .repoRoot = store.selectedWorkspace { return false }
    return true
  }

  /// Toggle binding: flipping ON restores the user's last typed branch
  /// query (if any) so the field doesn't surprise them with empty
  /// state; flipping OFF stashes the current query for next time and
  /// resets the selection to `.repoRoot`.
  private var useWorktreeBinding: Binding<Bool> {
    Binding(
      get: { isUsingWorktree },
      set: { newValue in
        if newValue {
          store.send(.workspaceSelected(.newBranch(name: lastBranchQuery)))
        } else {
          lastBranchQuery = store.workspaceQuery
          store.send(.workspaceSelected(.repoRoot))
        }
      }
    )
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
        // Use prompt: for the inline placeholder — passing it as the
        // title argument causes Form to render it as a leading label
        // next to the field, producing a broken-looking split layout.
        TextField(
          "Workspace branch",
          text: $store.workspaceQuery,
          prompt: Text("Branch or new name…")
        )
        .labelsHidden()
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: .infinity)
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
    case .repoRoot: return ""  // unreachable when the field is rendered
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

    // The "Repo root" entry used to live here as the default suggestion.
    // It moved out of this list when the worktree yes/no toggle landed —
    // the toggle handles "no worktree" directly, so showing it again
    // here would duplicate the affordance.

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
      Button("") { store.send(.agentSelected(nil)) }
        .keyboardShortcut("0", modifiers: .command)
        .hidden()
      Button("") { store.send(.agentSelected(.claude)) }
        .keyboardShortcut("1", modifiers: .command)
        .hidden()
      Button("") { store.send(.agentSelected(.codex)) }
        .keyboardShortcut("2", modifiers: .command)
        .hidden()
      // ⌘-Enter submits even while focus is in the multi-line prompt
      // editor (where plain Enter inserts a newline). The footer
      // Create button keeps `.defaultAction` so plain Enter still
      // submits when focus is elsewhere.
      Button("") { store.send(.createButtonTapped) }
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(store.isCreating)
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

  /// Closure handed to `PromptTextEditor` so it can highlight completed
  /// `<trigger><name>` tokens in the prompt that match a known skill.
  /// For Claude only the user-invocable subset gets the slash treatment;
  /// Codex's `$<name>` matches against everything in the catalog.
  private var skillNameValidator: ((String) -> Bool)? {
    guard let agent = skillAutocompleteAgent else { return nil }
    let validNames: Set<String>
    switch agent {
    case .claude:
      validNames = Set(skillCatalog.filter(\.isUserInvocable).map(\.name))
    case .codex:
      validNames = Set(skillCatalog.map(\.name))
    }
    guard !validNames.isEmpty else { return nil }
    return { validNames.contains($0) }
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

  /// X offset of the popover in the overlay's coordinate space. Anchored
  /// to the caret; clamped so the popover doesn't extend past the
  /// editor's right edge.
  private func floatingPopupX(for query: SkillQuery, editorRect: CGRect) -> CGFloat {
    let preferredWidth: CGFloat = 360
    let absoluteCaret = editorRect.minX + query.caretRect.minX
    let maxX = max(editorRect.maxX - preferredWidth, editorRect.minX)
    return min(max(absoluteCaret, editorRect.minX), maxX)
  }

  /// Y offset — directly below the caret line, with an 8pt gap.
  private func floatingPopupY(for query: SkillQuery, editorRect: CGRect) -> CGFloat {
    editorRect.minY + query.caretRect.maxY + 8
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
