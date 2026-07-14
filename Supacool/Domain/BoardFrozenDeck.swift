import Foundation

/// Membership rule for the board's frozen deck — the collapsed stack that
/// stands in for a pile of idle (detached) cards. Lives outside the SwiftUI
/// view so the rule stays testable, mirroring `BoardResumeEligibility`.
///
/// Only `.detached` collapses. `.interrupted` and `.disconnected` are also
/// cracked-glass, but they mean something went wrong — burying them behind a
/// stack would hide the one signal the user needs to act on. Priority-flagged
/// sessions are likewise exempt: the flag *is* the user saying "keep this
/// visible".
nonisolated enum BoardFrozenDeck {
  /// A stack of one is noise, not a simplification.
  static let minimumCount = 2

  static func members(
    visibleSessions: [AgentSession],
    isExpanded: Bool,
    classify: (AgentSession) -> BoardSessionStatus
  ) -> [AgentSession] {
    guard !isExpanded else { return [] }
    let candidates = visibleSessions.filter { session in
      classify(session) == .detached && !session.isPriority
    }
    guard candidates.count >= minimumCount else { return [] }
    return candidates
  }
}
