import Foundation

/// Transient card that floats in the bottom-right tray over the Matrix Board.
/// Emitted by system state (e.g. stale hooks) or user intent (e.g. a draft
/// New Terminal). Each card supports a primary tap and an optional dismiss.
/// Cards are not persisted — they live for the app session.
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
}
