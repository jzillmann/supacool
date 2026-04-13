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
      .help("Return to board (⌘B or Esc)")

      Divider().frame(height: 18)

      agentChip
      Text(session.displayName)
        .font(.headline)
        .lineLimit(1)
      Spacer()
      repoChip
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
  }

  private var agentChip: some View {
    HStack(spacing: 4) {
      Image(systemName: session.agent == .claude ? "brain" : "terminal.fill")
        .font(.caption)
      Text(session.agent.displayName)
        .font(.caption.weight(.medium))
    }
    .foregroundStyle(session.agent == .claude ? Color.purple : Color.cyan)
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .background((session.agent == .claude ? Color.purple : Color.cyan).opacity(0.12))
    .clipShape(Capsule())
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
      }
    }
  }

  @ViewBuilder
  private var terminalBody: some View {
    if let worktree = resolveWorktree() {
      WorktreeTerminalTabsView(
        worktree: worktree,
        manager: terminalManager,
        shouldRunSetupScript: false,
        forceAutoFocus: true,
        createTab: onNewTerminal
      )
      .id(worktree.id)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .ignoresSafeArea(.container, edges: .bottom)
    } else {
      detachedState
    }
  }

  private var detachedState: some View {
    VStack(spacing: 12) {
      Image(systemName: "moon.zzz.fill")
        .font(.system(size: 48))
        .foregroundStyle(.secondary)
      Text("Session detached")
        .font(.title3.weight(.medium))
      Text("The underlying terminal process is gone. Relaunch to reattach, or remove this card.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 380)
      Button("Back to Board", action: onBackToBoard)
        .keyboardShortcut(.defaultAction)
    }
    .padding(40)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  /// Look up the session's Worktree object. If the worktree isn't in the
  /// repository's currently-visible list (e.g. created via the New Terminal
  /// sheet's worktree mode and filtered out of the sidebar per Phase 3c's
  /// "don't open all worktrees by default"), synthesize a minimal one from
  /// the session metadata. The terminal manager only keys state by id so
  /// this works as long as the id matches.
  private func resolveWorktree() -> Worktree? {
    if let repo = repositories[id: session.repositoryID],
      let existing = repo.worktrees.first(where: { $0.id == session.worktreeID })
    {
      return existing
    }
    // Synthesize: the worktree's id is its working directory path.
    let url = URL(fileURLWithPath: session.worktreeID).standardizedFileURL
    let repoRoot =
      repositories[id: session.repositoryID]?.rootURL.standardizedFileURL ?? url
    // Only synthesize when the terminal manager knows about this tab —
    // otherwise it's genuinely detached.
    let tabID = TerminalTabID(rawValue: session.id)
    guard terminalManager.sessionTabExists(worktreeID: session.worktreeID, tabID: tabID) else {
      return nil
    }
    return Worktree(
      id: session.worktreeID,
      name: url.lastPathComponent,
      detail: "",
      workingDirectory: url,
      repositoryRootURL: repoRoot
    )
  }
}
