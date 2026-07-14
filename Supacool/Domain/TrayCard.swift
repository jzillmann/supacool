import Foundation

/// Short-lived notification card floating in the bottom-right tray over the
/// Matrix Board. Each card represents a transient signal ("hooks are out of
/// date", "a session is spawning") — not persistent UI. Every card supports
/// a primary tap (call-to-action) and × dismiss. Cards are not persisted;
/// they live for the duration of the signal.
nonisolated struct TrayCard: Identifiable, Equatable, Sendable {
  let id: UUID
  var kind: TrayCardKind

  init(id: UUID = UUID(), kind: TrayCardKind) {
    self.id = id
    self.kind = kind
  }
}

nonisolated enum TrayCardKind: Equatable, Sendable {
  /// One or more agent hook payloads in the user's settings.json differ from
  /// the payload this build expects. Primary tap opens Settings → Coding
  /// Agents; dismiss snoozes until the next app launch.
  case staleHooks(slots: [AgentHookSlot])

  /// A session was just submitted via New Terminal / Rerun / Resume and is
  /// still spawning its PTY. Auto-dismissed either on busy=true or when
  /// the watcher confirms the session is already live (shell sessions may
  /// never emit busy=true). Primary tap focuses the session so the user
  /// jumps straight into the fresh terminal.
  case sessionCreating(sessionID: AgentSession.ID, displayName: String)

  /// A worktree is being removed via `git worktree remove`. Auto-dismissed
  /// when `RepositoriesFeature.worktreeDeleted` fires (success) or replaced
  /// by `.worktreeDeleteFailed` on error. `worktreeID` is the worktree
  /// path (its stable identifier); `displayName` is the folder name shown
  /// in the card subtitle. Mirrors `.sessionCreating` visually (spinner
  /// leading indicator). Primary tap dismisses — there's nothing to
  /// navigate to during a transient delete.
  case worktreeDeleting(worktreeID: String, displayName: String)

  /// A hook install / reinstall errored. Surfaced as a red tray card so
  /// users see failures initiated from both the tray (reinstall on a
  /// stale-hooks card) and Settings → Coding Agents. Primary tap opens
  /// Settings so they can diagnose; × dismisses.
  case hookInstallFailed(slot: AgentHookSlot, message: String)

  /// `git worktree remove` failed during card-removal cleanup. Without
  /// this surface the directory would silently linger on disk — the
  /// only feedback was a `.debug` log. Primary tap dismisses (nothing
  /// to navigate to); user can rerun cleanup from Trash → Worktrees.
  case worktreeDeleteFailed(path: String, message: String)

  /// `SessionSpawner.spawnLocal` (or its remote sibling) threw a
  /// non-conflict error. Replaces the in-flight `.sessionCreating`
  /// placeholder so the user sees what went wrong instead of the
  /// previous silent disappearance. `displayName` is the placeholder's
  /// label so the user can correlate the failure with the intended
  /// session; `message` is `error.localizedDescription` from the throw.
  ///
  /// `draftSnapshot` carries a `Draft`-shaped snapshot of the user's
  /// in-flight submission (local path only — remote spawn failures
  /// surface via NewTerminalFeature directly without leaning on this
  /// card). When present, primary tap reopens the New Terminal sheet
  /// pre-filled with those values so the user can fix the issue,
  /// retry, or hit Save Draft. `nil` means the failure has no
  /// recoverable context (remote spawn or pre-existing serialized card
  /// from before this feature) — primary tap then just dismisses.
  case sessionSpawnFailed(displayName: String, message: String, draftSnapshot: Draft?)

  /// Resuming a detached session failed before any PTY was spawned — most
  /// commonly because the session's worktree was deleted when it was trashed
  /// and couldn't be rebuilt (its branch is gone too). Without this card the
  /// only feedback was a log line: the card just sat there detached, or —
  /// worse, before the worktree rebuild landed — the agent was resumed in
  /// whatever directory the shell fell back to and reported "No conversation
  /// found with session ID". Primary tap focuses the session so the user can
  /// Rerun it.
  case sessionResumeFailed(sessionID: AgentSession.ID, displayName: String, message: String)

  /// Whether this kind offers a secondary call-to-action button next to
  /// the main tap target. Only `.staleHooks` currently does ("Reinstall").
  var hasSecondaryAction: Bool {
    switch self {
    case .staleHooks: true
    case .sessionCreating, .worktreeDeleting, .hookInstallFailed,
      .worktreeDeleteFailed, .sessionSpawnFailed, .sessionResumeFailed: false
    }
  }

  /// The (title, message) pair this card surfaces, when applicable.
  /// Used by the tray's Copy button to put a meaningful string on the
  /// pasteboard and by the Debug button to seed the debug-session
  /// prompt. Non-error kinds return `nil`.
  var errorContent: (title: String, message: String)? {
    switch self {
    case .staleHooks, .sessionCreating, .worktreeDeleting: return nil
    case .hookInstallFailed(let slot, let message):
      let label: String = {
        switch slot {
        case .claudeProgress: "Claude Progress"
        case .claudeNotifications: "Claude Notifications"
        case .codexProgress: "Codex Progress"
        case .codexNotifications: "Codex Notifications"
        case .piExtension: "Pi Extension"
        }
      }()
      return ("\(label) install failed", message)
    case .worktreeDeleteFailed(let path, let message):
      let folder = URL(fileURLWithPath: path).lastPathComponent
      return ("Couldn't remove worktree \(folder)", message)
    case .sessionSpawnFailed(let displayName, let message, _):
      return ("Couldn't start \(displayName)", message)
    case .sessionResumeFailed(_, let displayName, let message):
      return ("Couldn't resume \(displayName)", message)
    }
  }
}
