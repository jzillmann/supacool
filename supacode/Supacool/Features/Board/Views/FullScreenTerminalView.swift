import AppKit
import ComposableArchitecture
import SwiftUI

/// Full-screen terminal view shown when a board card is tapped. Reuses
/// supacode's `WorktreeTerminalTabsView` (the same component the detail
/// pane uses to render a worktree's tab+split tree), wrapped in a minimal
/// Supacool header with a back button.
///
/// `Esc` returns to the board.
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

  /// The macOS app opened when the user clicks the diff button. Swap via
  /// `defaults write app.morethan.supacool supacool.gitGuiApp Tower`
  /// (or Fork, GitUp, SourceTree, etc.) until we surface a proper setting.
  @AppStorage("supacool.gitGuiApp") private var gitGuiApp: String = "Fork"

  /// Toggles the "Set Custom…" alert for overriding `gitGuiApp`.
  @State private var isEditingGitGuiApp: Bool = false
  @State private var gitGuiAppDraft: String = ""

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      terminalBody
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(
      Button("Escape") { onBackToBoard() }
        .keyboardShortcut(.escape, modifiers: [])
        .hidden()
    )
    .background(
      Button("Board") { onBackToBoard() }
        .keyboardShortcut("b", modifiers: .command)
        .hidden()
    )
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
      gitGuiButton
      Text(session.displayName)
        .font(.headline)
        .lineLimit(1)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onRename)
        .contextMenu {
          Button("Rename…", systemImage: "pencil", action: onRename)
        }
        .help("Double-click to rename")
      Spacer()
      agentChip
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

  /// Opens the configured git GUI (Fork by default) on the session's
  /// working directory. We let the GUI decide whether there's anything
  /// interesting to show — Fork/Tower handle a clean tree fine — rather
  /// than shelling out to `git status` on every render.
  /// Right-click picks a preset or opens a "Set Custom…" alert.
  @ViewBuilder
  private var gitGuiButton: some View {
    let url = URL(fileURLWithPath: session.worktreeID)
    Button {
      openInGitGui(url: url)
    } label: {
      Image(systemName: "plus.forwardslash.minus")
        .font(.system(size: 13, weight: .medium))
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .help("Open in \(gitGuiApp) (right-click to change)")
    .contextMenu {
      Section("Open diff in") {
        ForEach(Self.gitGuiPresets, id: \.self) { preset in
          Button {
            gitGuiApp = preset
          } label: {
            if preset == gitGuiApp {
              Label(preset, systemImage: "checkmark")
            } else {
              Text(preset)
            }
          }
        }
        Divider()
        Button("Set Custom…") {
          gitGuiAppDraft = gitGuiApp
          isEditingGitGuiApp = true
        }
      }
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
