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
  /// Primary tap dismisses (no native retry — user re-paste prompt
  /// into a fresh New Terminal sheet).
  case sessionSpawnFailed(displayName: String, message: String)

  /// Whether this kind offers a secondary call-to-action button next to
  /// the main tap target. Only `.staleHooks` currently does ("Reinstall").
  var hasSecondaryAction: Bool {
    switch self {
    case .staleHooks: true
    case .sessionCreating, .hookInstallFailed, .worktreeDeleteFailed,
      .sessionSpawnFailed: false
    }
  }
}
