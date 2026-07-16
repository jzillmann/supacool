import SwiftUI

/// Shows a blocking archive/delete/run script's terminal tab so the user
/// can read its output — most usefully *why* it failed. Reached from the
/// script-failed alert's "View Terminal".
///
/// The shell stays alive after the script exits (see
/// `handleBlockingScriptCommandFinished`), so this renders a live PTY, not
/// a transcript: a script parked on an interactive prompt can be answered
/// here.
struct ScriptTerminalSheet: View {
  let presentation: ScriptTerminalPresentation
  let terminalManager: WorktreeTerminalManager
  let onDismiss: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      SingleSessionTerminalView(
        worktree: presentation.worktree,
        tabID: presentation.tabID,
        manager: terminalManager
      )
    }
    .frame(minWidth: 640, minHeight: 420)
  }

  private var header: some View {
    HStack(spacing: 8) {
      // Decorative — the title beside it already names the script.
      Image(systemName: "terminal.fill")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 1) {
        Text(presentation.title)
          .font(.headline)
        Text(presentation.worktree.name)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer(minLength: 0)
      Button("Done", action: onDismiss)
        .keyboardShortcut(.cancelAction)
        .help("Close the script terminal and return to the board (⎋)")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }
}
