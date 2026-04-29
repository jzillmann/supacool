import AppKit
import ComposableArchitecture
import SwiftUI

/// Full-screen terminal view shown when a board card is tapped. Reuses
/// supacode's `WorktreeTerminalTabsView` (the same component the detail
/// pane uses to render a worktree's tab+split tree), wrapped in a minimal
/// Supacool header with a back button.
///
/// `⌘.` or `⌘B` returns to the board.
struct FullScreenTerminalView: View {
  let session: AgentSession
  let repositories: IdentifiedArrayOf<Repository>
  let worktreeInfoByID: [Worktree.ID: WorktreeInfoEntry]
  let terminalManager: WorktreeTerminalManager
  let onBackToBoard: () -> Void
  let onNewTerminal: () -> Void
  let onRerun: () -> Void
  /// Present for local raw-shell sessions so a detached shell can reopen
  /// the saved split layout and working directories without going through
  /// the new-terminal sheet.
  let onRestoreShellLayout: (() -> Void)?
  /// Present only when the session has a captured agent-native id and an
  /// agent CLI — shell sessions and pre-hook sessions can't be resumed.
  let onResume: (() -> Void)?
  /// Fallback resume path: invokes the agent's own built-in resume picker
  /// (e.g. `claude --resume`). Present for any agent session even if we
  /// never captured a native session id.
  let onResumePicker: (() -> Void)?
  /// Pause/park this session: mark parked and destroy the live PTY tab.
  /// Optional so parked sessions can hide the control.
  let onPark: (() -> Void)?
  let onRemove: () -> Void
  /// Present only for remote sessions whose ssh link has dropped. Clicked
  /// by the user from the disconnected state to re-spawn ssh and
  /// `tmux attach`.
  let onReconnect: (() -> Void)?
  /// Opens the rename alert owned by `BoardRootView`. Triggered from the
  /// header title (double-click) and its context menu.
  let onRename: () -> Void
  let onTogglePriority: () -> Void

  /// Called when the user confirms the "convert to worktree" popover on
  /// the repo-root pill. The board reducer creates the worktree on disk
  /// and types `cd '<path>'` into the focused surface — no surface or
  /// agent churn. Only meaningful while the session is running at the
  /// repo root; on a worktree the pill is not tappable.
  let onConvertToWorktree: (String) -> Void

  /// `⌘←/↑` → `-1`, `⌘→/↓` → `+1`. Signals the parent to open (or
  /// advance) the ⌘-Tab-style session switcher overlay. The overlay
  /// itself handles subsequent arrow keys once presented.
  let onSwitcherMove: (Int) -> Void

  /// Mirrors the board card's auto-observer affordance so the user can
  /// flip the observer on/off without going back to the board.
  let onAutoObserverToggle: () -> Void
  let onAutoObserverPromptChanged: (String) -> Void
  let onAutoObserverRunNow: () -> Void

  /// The macOS app opened when the user clicks the diff button. Swap via
  /// `defaults write app.morethan.supacool supacool.gitGuiApp Tower`
  /// (or Fork, GitUp, SourceTree, etc.) until we surface a proper setting.
  @AppStorage("supacool.gitGuiApp") private var gitGuiApp: String = "Fork"

  /// Toggles the "Set Custom…" alert for overriding `gitGuiApp`.
  @State private var isEditingGitGuiApp: Bool = false
  @State private var gitGuiAppDraft: String = ""
  @State private var isInfoPopoverShown: Bool = false
  @State private var isAutoObserverPopoverShown: Bool = false
  @State private var isQuickDiffPresented: Bool = false
  @State private var isConfirmingRemove: Bool = false
  @State private var isRecentPromptsPopoverShown: Bool = false
  @State private var isConvertPopoverShown: Bool = false
  /// Draft branch name shown in the convert-to-worktree popover.
  /// Initialized from the session display name when the popover opens.
  @State private var convertBranchDraft: String = ""

  /// First leaf we ever observed in this session's tab — the agent's
  /// own surface. Captured the first time the tab has exactly one leaf
  /// so the split toggle can identify it for the lifetime of the
  /// session and never close it by mistake.
  @State private var agentSurfaceID: UUID?

  /// Last `.outputTurn` delta loaded from the persisted transcript when
  /// the session is detached — gives the user a "where was I?" preview
  /// without reattaching. Nil while loading or when no agent turns were
  /// recorded (e.g. session never produced output before dying).
  @State private var lastAgentMessage: String?

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      terminalBody
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(
      // ⌘. is macOS's canonical "cancel/dismiss" and — unlike Esc — isn't
      // swallowed by vim/readline inside the terminal surface.
      Button("Back to Board") { onBackToBoard() }
        .keyboardShortcut(".", modifiers: .command)
        .hidden()
    )
    .background(
      Button("Board") { onBackToBoard() }
        .keyboardShortcut("b", modifiers: .command)
        .hidden()
    )
    .background(
      // ⌘W closes the focused terminal if the tab has splits, else
      // dismisses back to the board. Matches the macOS convention of
      // ⌘W = "close the nearest pane/window".
      Button("Close Terminal or Board") { closeCurrentTerminalOrBack() }
        .keyboardShortcut("w", modifiers: .command)
        .hidden()
    )
    .background(
      // ⌘⇧D opens the in-house quick-diff sheet.
      Button("Quick Diff") { isQuickDiffPresented = true }
        .keyboardShortcut("d", modifiers: [.command, .shift])
        .hidden()
    )
    .background(
      // ⌘E toggles the shell split beside the agent surface (mirrors
      // the header's split button).
      Button("Toggle Shell Split") { toggleShellSplit() }
        .keyboardShortcut("e", modifiers: .command)
        .hidden()
    )
    // ⌘-Tab-style session switcher. ⌘⌥← / ⌘⌥↑ cycle backward, ⌘⌥→ /
    // ⌘⌥↓ forward — picking ⌘⌥+arrow over plain ⌘+arrow keeps the
    // native "jump to start/end of line" shortcuts inside the terminal
    // surface usable. The overlay (owned by BoardRootView) takes focus
    // once open, so repeated arrow presses while the modifier combo
    // stays held go to the overlay — these bindings only need to fire
    // for the first press.
    .background(switcherShortcuts)
  }

  private var switcherShortcuts: some View {
    Group {
      Button("Prev Session") { onSwitcherMove(-1) }
        .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
      Button("Prev Session (up)") { onSwitcherMove(-1) }
        .keyboardShortcut(.upArrow, modifiers: [.command, .option])
      Button("Next Session") { onSwitcherMove(+1) }
        .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
      Button("Next Session (down)") { onSwitcherMove(+1) }
        .keyboardShortcut(.downArrow, modifiers: [.command, .option])
    }
    .hidden()
  }

  private var header: some View {
    HStack(spacing: 10) {
      Button(action: onBackToBoard) {
        HStack(spacing: 4) {
          Image(systemName: "chevron.left")
          Text("Board")
        }
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .help("Return to board (⌘B or ⌘.)")

      Divider().frame(height: 18)

      repoChip
      pullRequestStatus
      Text(session.displayName)
        .font(.headline)
        .lineLimit(1)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onRename)
        .contextMenu {
          Button("Rename…", systemImage: "pencil", action: onRename)
        }
        .help("Double-click to rename")
      priorityButton
      infoButton
      openDiffButton
      recentPromptsButton
      autoObserverButton
      splitButton
      Spacer()
      agentChip
      pauseButton
      removeButton
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
  }

  private var agentChip: some View {
    HStack(spacing: 4) {
      AgentIconView(agent: session.agent, size: 12)
      Text(AgentType.displayName(for: session.agent))
        .font(.caption.weight(.medium))
        .foregroundStyle(agentColor)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .background(agentColor.opacity(0.12))
    .clipShape(Capsule())
  }

  private var agentColor: Color {
    AgentType.tintColor(for: session.agent)
  }

  @ViewBuilder
  private var repoChip: some View {
    if let repo = repositories[id: session.repositoryID] {
      HStack(spacing: 6) {
        HStack(spacing: 4) {
          Image(systemName: "folder.fill")
            .font(.caption2)
            .foregroundStyle(.yellow)
          Text(repo.name)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        workspaceBadge
      }
    }
  }

  @ViewBuilder
  private var pullRequestStatus: some View {
    if let model = PullRequestStatusModel(
      pullRequest: Self.matchedPullRequest(
        session: session,
        repositories: repositories,
        worktreeInfoByID: worktreeInfoByID
      )
    ) {
      PullRequestStatusButton(model: model)
        .font(.caption)
        .padding(.leading, 2)
    }
  }

  /// Always-on workspace badge beside the repo name. On a worktree it
  /// shows the branch in accent color; at repo root it shows a muted
  /// "repo root" pill so the user is never in doubt about whether they
  /// are editing the tracked working copy directly.
  @ViewBuilder
  private var workspaceBadge: some View {
    if let worktreeLabel {
      HStack(spacing: 3) {
        Image(systemName: "arrow.triangle.branch")
          .font(.caption2)
        Text(worktreeLabel)
          .font(.caption.weight(.medium))
          .lineLimit(1)
      }
      .foregroundStyle(Color.accentColor)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(Color.accentColor.opacity(0.12))
      .clipShape(Capsule())
      .help("Running in worktree \(worktreeLabel)")
    } else {
      Button {
        convertBranchDraft = suggestedBranchName(from: session.displayName)
        isConvertPopoverShown = true
      } label: {
        HStack(spacing: 3) {
          Image(systemName: "dot.circle")
            .font(.caption2)
          Text("repo root")
            .font(.caption.weight(.medium))
          Image(systemName: "arrow.right.circle")
            .font(.caption2)
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.orange.opacity(0.12))
        .clipShape(Capsule())
      }
      .buttonStyle(.plain)
      .help("Running at repo root — click to create a worktree and cd into it.")
      .popover(isPresented: $isConvertPopoverShown, arrowEdge: .bottom) {
        convertToWorktreePopover
      }
    }
  }

  /// Popover content for the repo-root pill. Collects a branch name and
  /// commits the "create worktree + type `cd`" flow — see
  /// `BoardFeature.convertSessionToWorktree`.
  private var convertToWorktreePopover: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Create worktree")
        .font(.subheadline.weight(.semibold))
      Text("Creates a new branch + worktree, then types `cd '<path>'` into this terminal for you to run.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      TextField("branch-name", text: $convertBranchDraft)
        .textFieldStyle(.roundedBorder)
        .onSubmit { submitConvertToWorktree() }
      HStack {
        Spacer()
        Button("Cancel") { isConvertPopoverShown = false }
          .keyboardShortcut(.cancelAction)
        Button("Create") { submitConvertToWorktree() }
          .keyboardShortcut(.defaultAction)
          .disabled(trimmedConvertBranch.isEmpty)
      }
    }
    .padding(14)
    .frame(width: 320)
  }

  private var trimmedConvertBranch: String {
    convertBranchDraft.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func submitConvertToWorktree() {
    let name = trimmedConvertBranch
    guard !name.isEmpty else { return }
    onConvertToWorktree(name)
    isConvertPopoverShown = false
  }

  /// Best-effort slugifier: lowercases, keeps [a-z0-9], collapses any
  /// run of other characters into a single `-`, trims leading/trailing
  /// dashes, and caps at 40 chars so git-wt directory paths don't blow
  /// up. Returns an empty string for pathological input — the popover
  /// keeps the Create button disabled until the user types something.
  private func suggestedBranchName(from source: String) -> String {
    var result = ""
    var previousWasDash = false
    for scalar in source.lowercased().unicodeScalars {
      let char = Character(scalar)
      if char.isLetter || char.isNumber {
        result.append(char)
        previousWasDash = false
      } else if !previousWasDash {
        result.append("-")
        previousWasDash = true
      }
    }
    let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return String(trimmed.prefix(40))
  }

  /// Combined diff button: left-click opens the in-house QuickDiffSheet;
  /// right-click lets the user pick between the built-in view and any
  /// external git GUI (Fork, Tower, etc.). The currently selected
  /// external app is remembered in `gitGuiApp` and shown with a checkmark.
  @ViewBuilder
  private var openDiffButton: some View {
    // Diff is a display/context operation — show the user's current
    // workspace, not the immutable state anchor.
    let url = URL(fileURLWithPath: session.currentWorkspacePath)
    Button {
      isQuickDiffPresented = true
    } label: {
      Image(systemName: "plus.forwardslash.minus")
        .font(.system(size: 13, weight: .medium))
        .modifier(HeaderIconStyle())
    }
    .buttonStyle(.plain)
    .help("Open diff (⌘⇧D · right-click for external apps)")
    .contextMenu {
      Section("Open diff in") {
        Button {
          isQuickDiffPresented = true
        } label: {
          Label("Built-in Quick Diff (⌘⇧D)", systemImage: "plus.forwardslash.minus")
        }
        Divider()
        ForEach(Self.gitGuiPresets, id: \.self) { preset in
          Button {
            gitGuiApp = preset
            openInGitGui(url: url)
          } label: {
            if preset == gitGuiApp {
              Label(preset, systemImage: "checkmark")
            } else {
              Text(preset)
            }
          }
        }
        Divider()
        Button("Set Custom App…") {
          gitGuiAppDraft = gitGuiApp
          isEditingGitGuiApp = true
        }
      }
    }
    .sheet(isPresented: $isQuickDiffPresented) {
      QuickDiffSheet(
        worktreeURL: URL(fileURLWithPath: session.currentWorkspacePath),
        onDismiss: { isQuickDiffPresented = false }
      )
    }
    .alert("Git GUI app", isPresented: $isEditingGitGuiApp) {
      TextField("App name", text: $gitGuiAppDraft)
      Button("Cancel", role: .cancel) {}
      Button("Save") {
        let trimmed = gitGuiAppDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { gitGuiApp = trimmed }
      }
    } message: {
      Text("Name of the macOS app to launch (as it appears in /Applications). Used with `open -a`.")
    }
  }

  /// Small ⓘ button in the header that surfaces the session's initial
  /// config (prompt, agent, repo, worktree, captured resume id). Shares
  /// the same `SessionInfoPopover` view used by the board card.
  private var infoButton: some View {
    Button {
      isInfoPopoverShown.toggle()
    } label: {
      Image(systemName: "info.circle")
        .font(.system(size: 13, weight: .medium))
        .modifier(HeaderIconStyle())
    }
    .buttonStyle(.plain)
    .help("Show session details")
    .popover(isPresented: $isInfoPopoverShown, arrowEdge: .bottom) {
      SessionInfoPopover(
        session: session,
        repositoryName: repositories[id: session.repositoryID]?.name,
        worktreeLabel: worktreeLabel,
        onRerun: resolveWorktree() == nil ? onRerun : nil
      )
    }
  }

  private var priorityButton: some View {
    Button(action: onTogglePriority) {
      Image(systemName: session.isPriority ? "flag.fill" : "flag")
        .font(.system(size: 13, weight: .medium))
        .modifier(HeaderIconTintStyle(tint: session.isPriority ? .pink : .secondary))
    }
    .buttonStyle(.plain)
    .help(
      session.isPriority
        ? "Priority session - click to remove priority"
        : "Mark session as priority"
    )
  }

  /// Header button that pops up a list of reconstructed prompts from the
  /// session's transcript file. Selecting one fires Ghostty's search
  /// binding pre-populated with that prompt's first ~40 chars, so the
  /// user lands on the matching spot in the scrollback.
  private var recentPromptsButton: some View {
    Button {
      isRecentPromptsPopoverShown.toggle()
    } label: {
      Image(systemName: "text.line.first.and.arrowtriangle.forward")
        .font(.system(size: 13, weight: .medium))
        .modifier(HeaderIconStyle())
    }
    .buttonStyle(.plain)
    .help("Jump to a recent prompt")
    .popover(isPresented: $isRecentPromptsPopoverShown, arrowEdge: .bottom) {
      RecentPromptsPopover(
        tabID: TerminalTabID(rawValue: session.id),
        onJump: { needle in
          isRecentPromptsPopoverShown = false
          terminalManager.performBindingAction(
            worktreeID: session.worktreeID,
            action: "search:\(needle)"
          )
        }
      )
    }
  }

  /// Pause button beside delete. Uses the existing park flow: mark the
  /// session as parked and tear down its tab/surfaces.
  @ViewBuilder
  private var pauseButton: some View {
    if let onPark {
      Button(action: onPark) {
        Image(systemName: "pause.fill")
          .font(.system(size: 13, weight: .medium))
          .modifier(HeaderIconStyle())
      }
      .buttonStyle(.plain)
      .help("Pause terminal")
    }
  }

  /// Trash button at the right edge of the header. Trips a
  /// confirmation dialog before invoking `onRemove`, so a stray click
  /// can't nuke an active session in one shot. No keyboard shortcut —
  /// the terminal surface owns all common modifier+key combos.
  private var removeButton: some View {
    Button {
      isConfirmingRemove = true
    } label: {
      Image(systemName: "trash")
        .font(.system(size: 13, weight: .medium))
        .modifier(HeaderIconStyle())
    }
    .buttonStyle(.plain)
    .help("Delete this session")
    .confirmationDialog(
      "Delete \"\(session.displayName)\"?",
      isPresented: $isConfirmingRemove,
      titleVisibility: .visible
    ) {
      Button("Delete", role: .destructive, action: onRemove)
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Removes the session card and its terminal. Worktree directories created by Supacool are also deleted.")
    }
  }

  /// Mirrors the board card's sparkle button so the user can toggle the
  /// auto-observer (and edit its instructions) without leaving the
  /// terminal. Glows in accent color when the observer is active.
  private var autoObserverButton: some View {
    Button {
      isAutoObserverPopoverShown.toggle()
    } label: {
      Image(systemName: "sparkles")
        .font(.system(size: 13, weight: .medium))
        .modifier(HeaderIconTintStyle(tint: session.autoObserver ? .accentColor : .secondary))
    }
    .buttonStyle(.plain)
    .help("Auto-responder: auto-answer obvious prompts (click to configure)")
    .popover(isPresented: $isAutoObserverPopoverShown, arrowEdge: .bottom) {
      AutoObserverPopover(
        session: session,
        onToggle: onAutoObserverToggle,
        onPromptChanged: onAutoObserverPromptChanged,
        onRunNow: onAutoObserverRunNow
      )
    }
  }

  /// Header button that toggles a single shell split beside the agent
  /// surface. Only ever toggles between 1 and 2 leaves: clicking when a
  /// split exists (no matter who created it — us or Ghostty's ⌘D)
  /// closes every non-agent leaf. Mirrored by ⌘E.
  @ViewBuilder
  private var splitButton: some View {
    let worktree = resolveWorktree()
    let isSplit = currentLeafCount(worktree: worktree) > 1
    Button {
      toggleShellSplit()
    } label: {
      Image(systemName: isSplit ? "rectangle" : "rectangle.split.2x1")
        .font(.system(size: 13, weight: .medium))
        .modifier(HeaderIconStyle())
    }
    .buttonStyle(.plain)
    .disabled(worktree == nil)
    .help(isSplit ? "Close the shell split (⌘E)" : "Open a plain shell split in this session (⌘E)")
    .onChange(of: session.id) { _, _ in agentSurfaceID = nil }
    .task(id: session.id) { captureAgentSurfaceIfNeeded() }
  }

  /// Toggle the shell split beside the agent surface. With 2+ leaves,
  /// close every non-agent leaf so the toolbar always returns to the
  /// single-pane state. With 1 leaf, split to the right.
  private func toggleShellSplit() {
    guard let worktree = resolveWorktree() else { return }
    let state = terminalManager.state(for: worktree) { false }
    let tabID = TerminalTabID(rawValue: session.id)
    guard state.containsTabTree(tabID) else { return }
    let leaves = state.splitTree(for: tabID).leaves()
    captureAgentSurfaceIfNeeded(leaves: leaves)
    if leaves.count > 1 {
      for leaf in leaves where leaf.id != agentSurfaceID {
        _ = state.closeSurface(id: leaf.id)
      }
    } else {
      _ = state.splitFocusedSurface(in: tabID, direction: .right)
    }
  }

  private func currentLeafCount(worktree: Worktree?) -> Int {
    guard let worktree else { return 0 }
    let state = terminalManager.state(for: worktree) { false }
    let tabID = TerminalTabID(rawValue: session.id)
    guard state.containsTabTree(tabID) else { return 0 }
    return state.splitTree(for: tabID).leaves().count
  }

  private func captureAgentSurfaceIfNeeded(leaves: [GhosttySurfaceView]? = nil) {
    guard agentSurfaceID == nil else { return }
    let resolved: [GhosttySurfaceView]
    if let leaves {
      resolved = leaves
    } else {
      guard let worktree = resolveWorktree() else { return }
      let state = terminalManager.state(for: worktree) { false }
      let tabID = TerminalTabID(rawValue: session.id)
      guard state.containsTabTree(tabID) else { return }
      resolved = state.splitTree(for: tabID).leaves()
    }
    if resolved.count == 1 {
      agentSurfaceID = resolved[0].id
    }
  }

  /// Backs ⌘W. If the session's tab has multiple leaves, close the
  /// focused one (native Ghostty behavior). Otherwise fall back to
  /// "back to board" — the less destructive of the two options the
  /// user suggested.
  private func closeCurrentTerminalOrBack() {
    guard let worktree = resolveWorktree() else {
      onBackToBoard()
      return
    }
    let state = terminalManager.state(for: worktree) { false }
    let tabID = TerminalTabID(rawValue: session.id)
    guard state.containsTabTree(tabID) else {
      onBackToBoard()
      return
    }
    let leaves = state.splitTree(for: tabID).leaves()
    if leaves.count > 1 {
      state.closeFocusedSurface()
    } else {
      onBackToBoard()
    }
  }

  /// Built-in presets for the right-click menu. Manually curated — these
  /// are the common macOS git GUIs. Custom entries go through the
  /// "Set Custom…" alert.
  private static let gitGuiPresets: [String] = [
    "Fork",
    "Tower",
    "GitUp",
    "SourceTree",
    "GitHub Desktop",
    "Sublime Merge",
    "GitKraken",
  ]

  private func openInGitGui(url: URL) {
    let process = Process()
    process.launchPath = "/usr/bin/open"
    process.arguments = ["-a", gitGuiApp, url.path]
    do {
      try process.run()
    } catch {
      // Fall back to Finder if the configured app isn't installed. Users
      // see Finder instead of silence; they can then set a different app.
      NSWorkspace.shared.open(url)
    }
  }

  /// The worktree's branch (or its directory name as a fallback) — shown
  /// only when the session is running in a dedicated worktree, not at the
  /// repo root. Returns `nil` for directory-mode sessions so we don't
  /// duplicate the repo name. Reads `currentWorkspacePath` so that a
  /// session converted from repo root to a worktree shows the new branch
  /// immediately, even though its underlying terminal state stays keyed
  /// on the original `worktreeID`.
  private var worktreeLabel: String? {
    guard let repo = repositories[id: session.repositoryID] else { return nil }
    let rootPath = repo.rootURL.standardizedFileURL.path(percentEncoded: false)
    let workspacePath = session.currentWorkspacePath
    guard workspacePath != rootPath else { return nil }
    if let worktree = repo.worktrees.first(where: { $0.id == workspacePath }) {
      return worktree.branch ?? worktree.name
    }
    return URL(fileURLWithPath: workspacePath).lastPathComponent
  }

  @MainActor
  static func matchedPullRequest(
    session: AgentSession,
    repositories: IdentifiedArrayOf<Repository>,
    worktreeInfoByID: [Worktree.ID: WorktreeInfoEntry]
  ) -> GithubPullRequest? {
    guard let repo = repositories[id: session.repositoryID] else { return nil }
    let rootPath = repo.rootURL.standardizedFileURL.path(percentEncoded: false)
    let workspacePath = session.currentWorkspacePath
    guard workspacePath != rootPath else { return nil }
    guard let worktree = repo.worktrees.first(where: { $0.id == workspacePath }) else {
      return nil
    }
    let pullRequest = worktreeInfoByID[workspacePath]?.pullRequest
    guard let pullRequest else { return nil }
    guard pullRequest.headRefName == nil || pullRequest.headRefName == worktree.name else {
      return nil
    }
    return pullRequest
  }

  @ViewBuilder
  private var terminalBody: some View {
    if let worktree = resolveWorktree() {
      // Render only THIS session's tab — not the worktree's whole tab
      // bar + all sibling tabs. The board is the tab-bar-equivalent in
      // Supacool; each card is one session, and clicking one should
      // show only that session's terminal tree.
      SingleSessionTerminalView(
        worktree: worktree,
        tabID: TerminalTabID(rawValue: session.id),
        manager: terminalManager
      )
      .id(session.id)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .ignoresSafeArea(.container, edges: .bottom)
    } else if session.isRemote {
      disconnectedRemoteState
    } else {
      detachedState
    }
  }

  /// Shown when a remote session's ssh surface has died. Tmux on the far
  /// side almost always survived, so the primary affordance is Reconnect
  /// (re-spawn ssh → `tmux new-session -A`), not Rerun.
  private var disconnectedRemoteState: some View {
    VStack(spacing: 14) {
      Image(systemName: "bolt.slash.fill")
        .font(.system(size: 48))
        .foregroundStyle(.red)
      Text("Disconnected from remote")
        .font(.title3.weight(.medium))
      Text("""
        The SSH link dropped. Your tmux session on the remote almost \
        certainly survived — click Reconnect to re-attach.
        """)
      .font(.callout)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .frame(maxWidth: 420)

      HStack(spacing: 10) {
        Button(role: .destructive) {
          onRemove()
        } label: {
          Label("Remove", systemImage: "trash")
        }
        Button("Back to Board", action: onBackToBoard)
        if let onReconnect {
          Button("Reconnect", systemImage: "arrow.clockwise", action: onReconnect)
            .keyboardShortcut(.defaultAction)
            .help("Re-spawn ssh and tmux attach to the existing remote session")
        }
      }
    }
    .padding(40)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var detachedDescription: String {
    if session.agent == nil {
      return """
        The underlying shell process is gone — most likely because the app relaunched. \
        Restore the saved layout to reopen panes in their last known folders.
        """
    }
    return """
      The underlying terminal process is gone — most likely because the app \
      relaunched. The original prompt is preserved.
      """
  }

  private var detachedPromptLabel: String {
    session.agent == nil ? "Initial command" : "Original prompt"
  }

  private var shouldShowRerunButton: Bool {
    session.agent != nil || !session.initialPrompt.isEmpty
  }

  private var detachedRerunLabel: String {
    session.agent == nil ? "Rerun Command" : "Rerun"
  }

  private var detachedState: some View {
    VStack(spacing: 14) {
      Image(systemName: "moon.zzz.fill")
        .font(.system(size: 48))
        .foregroundStyle(.secondary)
      Text("Session detached")
        .font(.title3.weight(.medium))
      Text(detachedDescription)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 420)

      if session.agent != nil || !session.initialPrompt.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          Label(detachedPromptLabel, systemImage: "quote.opening")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
          Text(session.initialPrompt)
            .font(.callout)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: 460)
        .padding(.top, 6)
      }

      if let lastAgentMessage {
        VStack(alignment: .leading, spacing: 4) {
          Label("Last response", systemImage: "bubble.left")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
          ScrollView {
            Text(lastAgentMessage)
              .font(.callout.monospaced())
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(maxHeight: 180)
          .padding(10)
          .background(Color.secondary.opacity(0.08))
          .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: 460)
      }

      HStack(spacing: 10) {
        Button(role: .destructive) {
          onRemove()
        } label: {
          Label("Remove", systemImage: "trash")
        }
        if let onRestoreShellLayout {
          Button("Restore Layout", systemImage: "rectangle.split.3x1", action: onRestoreShellLayout)
            .keyboardShortcut(.defaultAction)
            .help("Reopen shell panes using the last saved layout and working directories")
        }
        if shouldShowRerunButton {
          let rerunIsDefault = onRestoreShellLayout == nil && onResume == nil && onResumePicker == nil
          Button(detachedRerunLabel, systemImage: "arrow.clockwise", action: onRerun)
            .keyboardShortcut(rerunIsDefault ? KeyboardShortcut.defaultAction : nil)
        }
        if let onResume {
          Button("Resume", systemImage: "play.circle", action: onResume)
            .keyboardShortcut(.defaultAction)
            .help("Resume the captured \(AgentType.displayName(for: session.agent)) session")
        } else if let onResumePicker {
          Button("Resume…", systemImage: "play.circle", action: onResumePicker)
            .help(
              "No session id was captured. Launches \(AgentType.displayName(for: session.agent))'s built-in session picker for this directory."
            )
        }
        Button("Back to Board", action: onBackToBoard)
      }
    }
    .padding(40)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task(id: session.id) {
      await loadLastAgentMessage()
    }
  }

  /// Read the persisted transcript for this session and surface the most
  /// recent `.outputTurn` delta (what the agent said last) as a preview.
  /// Runs off-main since the file can be large; on Swift 6 the static
  /// `loadEntries` is `nonisolated` so a detached Task is the cleanest hop.
  private func loadLastAgentMessage() async {
    // TerminalTabID's initializer is main-actor-isolated under Swift 6's
    // global @MainActor — construct it here, then capture the value into
    // the detached Task so the disk read happens off-main.
    let tabID = TerminalTabID(rawValue: session.id)
    let preview = await Task.detached(priority: .userInitiated) { [tabID] () -> String? in
      let entries = TranscriptReader.loadEntries(tabID: tabID)
      for entry in entries.reversed() {
        guard case .outputTurn(_, let delta, _) = entry else { continue }
        let trimmed = delta.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { continue }
        // Cap the preview so a multi-thousand-line dump doesn't blow up the
        // detached card. The ScrollView still lets the user scroll within.
        let maxChars = 4_000
        if trimmed.count > maxChars {
          return String(trimmed.suffix(maxChars))
        }
        return trimmed
      }
      return nil
    }.value
    lastAgentMessage = preview
  }

  /// Resolve the Worktree value that backs this session — used to drive
  /// `SingleSessionTerminalView` / `manager.state(for:)`.
  ///
  /// CRITICAL: the returned `.id` is always `session.worktreeID` verbatim,
  /// never a `repository.worktrees` record's id. `WorktreeTerminalManager`
  /// keys its `states` dictionary by `worktree.id`, and tabs were originally
  /// registered under `session.worktreeID`. If we returned a supacode-
  /// discovered record whose id was normalized differently (trailing slash,
  /// etc.), `state(for:)` would lazily create a fresh empty state under the
  /// mismatched key — the view would render "Terminal no longer running"
  /// even though the real tab exists under the session's own key.
  ///
  /// Returns nil when the terminal manager has no tab for this session —
  /// the detached/resume UI takes over in that case.
  private func resolveWorktree() -> Worktree? {
    let tabID = TerminalTabID(rawValue: session.id)
    guard terminalManager.sessionTabExists(worktreeID: session.worktreeID, tabID: tabID) else {
      return nil
    }
    let url = URL(fileURLWithPath: session.worktreeID).standardizedFileURL
    let repo = repositories[id: session.repositoryID]
    let discovered = repo?.worktrees.first(where: { $0.id == session.worktreeID })
    return Worktree(
      id: session.worktreeID,
      name: discovered?.name ?? url.lastPathComponent,
      detail: discovered?.detail ?? "",
      workingDirectory: discovered?.workingDirectory ?? url,
      repositoryRootURL: repo?.rootURL.standardizedFileURL ?? url,
      createdAt: discovered?.createdAt,
      branch: discovered?.branch
    )
  }
}

/// Shared visual for the full-screen header's icon-button cluster
/// (git-GUI, quick-diff, split, info). Uniform padding + a subtle
/// rounded background that lights up on hover, so the whole row reads
/// as one affordance group.
private struct HeaderIconStyle: ViewModifier {
  @State private var isHovered = false

  func body(content: Content) -> some View {
    content
      .foregroundStyle(.secondary)
      .padding(.horizontal, 6)
      .padding(.vertical, 4)
      .background(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(Color.primary.opacity(isHovered ? 0.12 : 0))
      )
      .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
      .onHover { isHovered = $0 }
      .animation(.easeOut(duration: 0.12), value: isHovered)
  }
}

/// Variant of `HeaderIconStyle` that lets the caller pick the foreground
/// tint — used by the auto-observer button so it can switch between the
/// inactive secondary tone and the accent-color "active" tone without
/// losing the shared hover background.
private struct HeaderIconTintStyle: ViewModifier {
  let tint: Color
  @State private var isHovered = false

  func body(content: Content) -> some View {
    content
      .foregroundStyle(tint)
      .padding(.horizontal, 6)
      .padding(.vertical, 4)
      .background(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(Color.primary.opacity(isHovered ? 0.12 : 0))
      )
      .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
      .onHover { isHovered = $0 }
      .animation(.easeOut(duration: 0.12), value: isHovered)
  }
}
