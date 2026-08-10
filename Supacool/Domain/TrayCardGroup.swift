import Foundation

/// Collapse key for tray cards that are *interchangeable* — cards whose only
/// per-card information is a name, so a reader loses nothing when N of them
/// fold into one "Starting 13 sessions" card. Error cards have no key: each
/// one carries a distinct message and must stay legible on its own.
nonisolated enum TrayCardCollapseKey: Hashable, Sendable {
  case sessionCreating
  case worktreeDeleting
}

/// One rendered slot in the tray: either a single card, or several
/// same-kind cards folded together.
///
/// Why this exists: starting a fleet at once (a Linear inbox batch, a
/// multi-select rerun) painted one spinner card per session and wallpapered
/// the bottom of the window — especially bad over a full-screen terminal,
/// where the cards cover the agent's output. Folding is a display concern
/// only; the reducer still tracks one `TrayCard` per in-flight session, so
/// auto-dismissal stays per session and the group shrinks as they land.
nonisolated struct TrayCardGroup: Identifiable, Equatable, Sendable {
  /// Every card in this slot, in tray order. Never empty.
  let cards: [TrayCard]

  private init(cards: [TrayCard]) {
    self.cards = cards
  }

  /// Identity follows the first member so a group keeps its place (and its
  /// transition) while later members come and go.
  var id: UUID { cards[0].id }

  /// The card that decides icon, tint, and — when the group holds one card
  /// — the whole presentation.
  var lead: TrayCard { cards[0] }

  var isCollapsed: Bool { cards.count > 1 }

  /// Display names of the members, in tray order. Empty for kinds that
  /// don't carry one (they never collapse anyway).
  var displayNames: [String] { cards.compactMap(\.kind.displayName) }

  /// Folds `cards` into render slots, preserving first-appearance order so
  /// an uncollapsible card sitting between two spinners doesn't jump.
  static func group(_ cards: some Collection<TrayCard>) -> [TrayCardGroup] {
    var slots: [Slot] = []
    var buckets: [TrayCardCollapseKey: [TrayCard]] = [:]

    for card in cards {
      guard let key = card.kind.collapseKey else {
        slots.append(.single(card))
        continue
      }
      if buckets[key] == nil {
        slots.append(.bucket(key))
        buckets[key] = []
      }
      buckets[key]?.append(card)
    }

    return slots.compactMap { slot in
      switch slot {
      case .single(let card):
        return TrayCardGroup(cards: [card])
      case .bucket(let key):
        guard let members = buckets[key], !members.isEmpty else { return nil }
        return TrayCardGroup(cards: members)
      }
    }
  }
}

/// One slot in the ordered render list, resolved to a `TrayCardGroup` once
/// every card has been bucketed. File-scope because a generic function can't
/// nest a type.
private enum Slot {
  case single(TrayCard)
  case bucket(TrayCardCollapseKey)
}

extension TrayCardKind {
  /// Non-nil for kinds that may fold together in the tray.
  nonisolated var collapseKey: TrayCardCollapseKey? {
    switch self {
    case .sessionCreating: .sessionCreating
    case .worktreeDeleting: .worktreeDeleting
    case .staleHooks, .hookInstallFailed, .worktreeDeleteFailed,
      .sessionSpawnFailed, .sessionResumeFailed:
      nil
    }
  }

  /// The subject this card is about, when it has one.
  nonisolated var displayName: String? {
    switch self {
    case .sessionCreating(_, let displayName): displayName
    case .worktreeDeleting(_, let displayName): displayName
    case .sessionSpawnFailed(let displayName, _, _): displayName
    case .sessionResumeFailed(_, let displayName, _): displayName
    case .staleHooks, .hookInstallFailed, .worktreeDeleteFailed: nil
    }
  }
}
