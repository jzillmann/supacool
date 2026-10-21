/// How many cards each card context-menu verb acts on. More than one when the
/// right-clicked card is part of a multi-selection, so the menu can say so.
nonisolated struct SelectionMenuCounts: Equatable, Sendable {
  var park = 1
  var standby = 1
  var snooze = 1
  var remove = 1

  /// "Park" for one card, "Park 3 Selected" for a selection.
  static func label(_ verb: String, count: Int) -> String {
    count > 1 ? "\(verb) \(count) Selected" : verb
  }
}
