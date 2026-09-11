/// ⌘1–⌘9 map onto a session's tab strip (`AgentSession.tabTerminals`) the
/// way browsers map them onto tabs: ⌘1–⌘8 pick that position, ⌘9 always
/// picks the last tab, however many there are.
nonisolated enum SessionTabShortcut {
  static let digits = 1...9

  /// Index into the tab list that ⌘`digit` selects, or nil when there is
  /// no such tab (the shortcut then stays disabled and does nothing).
  static func tabIndex(forDigit digit: Int, tabCount: Int) -> Int? {
    guard digits.contains(digit), tabCount > 0 else { return nil }
    if digit == 9 { return tabCount - 1 }
    return digit <= tabCount ? digit - 1 : nil
  }

  /// The digit whose ⌘-shortcut reaches the tab at `index` — for tooltips.
  /// Tabs past the 8th have none, except the last one (⌘9).
  static func digit(forTabAt index: Int, tabCount: Int) -> Int? {
    guard index >= 0, index < tabCount else { return nil }
    if index < 8 { return index + 1 }
    return index == tabCount - 1 ? 9 : nil
  }
}
