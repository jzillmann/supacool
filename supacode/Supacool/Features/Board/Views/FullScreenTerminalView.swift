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
  let terminalManager: WorktreeTerminalManager
  let onBackToBoard: () -> Void
  let onNewTerminal: () -> Void
  let onRerun: () -> Void
  /// Present only when the session has a captured agent-native id and an
  /// agent CLI — shell sessions and pre-hook sessions can't be resumed.
  let onResume: (() -> Void)?
  /// Fallback resume path: invokes the agent's own built-in resume picker
  /// (e.g. `claude --resume`). Present for any agent session even if we
  /// never captured a native session id.
  let onResumePicker: (() -> Void)?
  let onRemove: () -> Void
  /// Opens the rename alert owned by `BoardRootView`. Triggered from the
  /// header title (double-click) and its context menu.
  let onRename: () -> Void

  /// `⌘←/↑` → `-1`, `⌘→/↓` → `+1`. Signals the parent to open (or
  /// advance) the ⌘-Tab-style session switcher overlay. The overlay
  /// itself handles subsequent arrow keys once presented.
  let onSwitcherMove: (Int) -> Void

  /// Mirrors the board card's auto-observer affordance so the user can
  /// flip the observer on/off without going back to the board.
  let onAutoObserverToggle: () -> Void
  let onAutoObserverPromptChanged: (String) -> Void

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

  /// Surface id of the split we created via the header button — `nil`
  /// when the button is in "create" mode, non-nil when in "close" mode.
  /// Reconciled from the live leaf set so closing the split via
  /// Ghostty's own keybindings (⌘D) flips the button back to "create".
  @State private var managedSplitSurfaceID: UUID?

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
      Text(session.displayName)
        .font(.headline)
        .lineLimit(1)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onRename)
        .contextMenu {
          Button("Rename…", systemImage: "pencil", action: onRename)
        }
        .help("Double-click to rename")
      infoButton
      autoObserverButton
      openDiffButton
      splitButton
      Spacer()
      agentChip
      removeButton
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
  }

  private var agentChip: some View {
    HStack(spacing: 4) {
      Image(systemName: agentIcon)
        .font(.caption)
      Text(AgentType.displayName(for: session.agent))
        .font(.caption.weight(.medium))
    }
    .foregroundStyle(agentColor)
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .background(agentColor.opacity(0.12))
    .clipShape(Capsule())
  }

  private var agentIcon: String {
    switch session.agent {
    case .claude: "brain"
    case .codex: "terminal.fill"
    case .none: "apple.terminal"
    }
  }

  private var agentColor: Color {
    switch session.agent {
    case .claude: .purple
    case .codex: .cyan
    case .none: .secondary
    }
  }

  @ViewBuilder
  private var repoChip: some View {
    if let repo = repositories[id: session.repositoryID] {
      HStack(spacing: 4) {
        Image(systemName: "folder.fill")
          .font(.caption2)
          .foregroundStyle(.yellow)
        Text(repo.name)
          .font(.caption)
          .foregroundStyle(.secondary)
        if let worktreeLabel {
          Image(systemName: "arrow.triangle.branch")
            .font(.caption2)
            .foregroundStyle(.tertiary)
          Text(worktreeLabel)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
    }
  }

  /// Combined diff button: left-click opens the in-house QuickDiffSheet;
  /// right-click lets the user pick between the built-in view and any
  /// external git GUI (Fork, Tower, etc.). The currently selected
  /// external app is remembered in `gitGuiApp` and shown with a checkmark.
  @ViewBuilder
  private var openDiffButton: some View {
    let url = URL(fileURLWithPath: session.worktreeID)
    Button {
      isQuickDiffPresented = true
    } label: {
      Image(systemName: "text.magnifyingglass")
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
          Label("Built-in Quick Diff (⌘⇧D)", systemImage: "text.magnifyingglass")
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
        worktreeURL: URL(fileURLWithPath: session.worktreeID),
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

  /// Toggles a plain-shell split beside the agent surface in this
  /// session's tab. First click splits; second click closes the split
  /// we created (does NOT open a third). If the user closed our split
  /// via Ghostty's own ⌘D, `managedSplitSurfaceID` is reconciled to nil

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
    .help("Auto-observer: auto-answer obvious prompts (click to configure)")
    .popover(isPresented: $isAutoObserverPopoverShown, arrowEdge: .bottom) {
      AutoObserverPopover(
        session: session,
        onToggle: onAutoObserverToggle,
        onPromptChanged: onAutoObserverPromptChanged
      )
    }
  }

  /// on the next render so the button flips back to "create" mode.
  @ViewBuilder
  private var splitButton: some View {
    let worktree = resolveWorktree()
    let managedStillLive = managedSplitStillLive(worktree: worktree)
    Button {
      toggleShellSplit()
    } label: {
      Image(systemName: managedStillLive ? "rectangle" : "rectangle.split.2x1")
        .font(.system(size: 13, weight: .medium))
        .modifier(HeaderIconStyle())
    }
    .buttonStyle(.plain)
    .disabled(worktree == nil)
    .help(managedStillLive ? "Close the shell split (⌘E)" : "Open a plain shell split in this session (⌘E)")
    .onChange(of: session.id) { _, _ in managedSplitSurfaceID = nil }
    .task(id: session.id) { reconcileManagedSplit() }
  }

  /// Toggle the shell split beside the agent surface. If the split we
  /// created is still live, close it; otherwise open a fresh one to the
  /// right. Mirrored by ⌘E.
  private func toggleShellSplit() {
    guard let worktree = resolveWorktree() else { return }
    let state = terminalManager.state(for: worktree) { false }
    let tabID = TerminalTabID(rawValue: session.id)
    if let id = managedSplitSurfaceID, managedSplitStillLive(worktree: worktree) {
      state.closeSurface(id: id)
      managedSplitSurfaceID = nil
    } else {
      managedSplitSurfaceID = state.splitFocusedSurface(in: tabID, direction: .right)
    }
  }

  /// Whether our tracked split surface is still in the tab's leaf set.
  /// If the user closed it via Ghostty's own ⌘D we shouldn't stay in
  /// "close" mode — the next click should split again.
  private func managedSplitStillLive(worktree: Worktree?) -> Bool {
    guard let worktree, let id = managedSplitSurfaceID else { return false }
    let state = terminalManager.state(for: worktree) { false }
    let tabID = TerminalTabID(rawValue: session.id)
    guard state.containsTabTree(tabID) else { return false }
    return state.splitTree(for: tabID).leaves().contains { $0.id == id }
  }

  private func reconcileManagedSplit() {
    guard let worktree = resolveWorktree() else {
      managedSplitSurfaceID = nil
      return
    }
    if !managedSplitStillLive(worktree: worktree) {
      managedSplitSurfaceID = nil
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
  /// duplicate the repo name.
  private var worktreeLabel: String? {
    guard let repo = repositories[id: session.repositoryID] else { return nil }
    let rootPath = repo.rootURL.standardizedFileURL.path(percentEncoded: false)
    guard session.worktreeID != rootPath else { return nil }
    if let worktree = repo.worktrees.first(where: { $0.id == session.worktreeID }) {
      return worktree.branch ?? worktree.name
    }
    return URL(fileURLWithPath: session.worktreeID).lastPathComponent
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
    } else {
      detachedState
    }
  }

  private var detachedState: some View {
    VStack(spacing: 14) {
      Image(systemName: "moon.zzz.fill")
        .font(.system(size: 48))
        .foregroundStyle(.secondary)
      Text("Session detached")
        .font(.title3.weight(.medium))
      Text("""
        The underlying terminal process is gone — most likely because the app \
        relaunched. The original prompt is preserved.
        """)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 420)

      VStack(alignment: .leading, spacing: 4) {
        Label("Original prompt", systemImage: "quote.opening")
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

      HStack(spacing: 10) {
        Button(role: .destructive) {
          onRemove()
        } label: {
          Label("Remove", systemImage: "trash")
        }
        let rerunIsDefault = onResume == nil && onResumePicker == nil
        Button("Rerun", systemImage: "arrow.clockwise", action: onRerun)
          .keyboardShortcut(rerunIsDefault ? KeyboardShortcut.defaultAction : nil)
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
