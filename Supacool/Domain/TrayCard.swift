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
  /// still spawning its PTY. Auto-dismissed when the session reports its
  /// first busy transition (= the agent is running). Primary tap focuses
  /// the session so the user jumps straight into the fresh terminal.
  case sessionCreating(sessionID: AgentSession.ID, displayName: String)
}
