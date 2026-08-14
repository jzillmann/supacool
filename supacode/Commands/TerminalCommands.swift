import SwiftUI

// Supacool: the New Terminal / Close Terminal / Close Terminal Tab menu items
// used to live here, driven by focused values the deleted sidebar published.
// Since that deletion (8dae4c31) nothing set them, so the items were
// permanently disabled *while still reserving ⌘W / ⌘⌥W / ⌘T at the menu
// level* — which is what made ⌘W ambiguous. They are gone; ⌘T and ⌘⌥W now
// fall straight through to Ghostty's own new_tab / close_tab bindings, and
// ⌘W belongs to the board (see AppShortcuts.reservedGhosttyUnbindArguments).
struct TerminalCommands: Commands {
  let ghosttyShortcuts: GhosttyShortcutManager
  @FocusedValue(\.startSearchAction) private var startSearchAction
  @FocusedValue(\.searchSelectionAction) private var searchSelectionAction
  @FocusedValue(\.navigateSearchNextAction) private var navigateSearchNextAction
  @FocusedValue(\.navigateSearchPreviousAction) private var navigateSearchPreviousAction
  @FocusedValue(\.endSearchAction) private var endSearchAction

  var body: some Commands {
    CommandGroup(after: .textEditing) {
      Button("Find...") {
        startSearchAction?()
      }
      .modifier(
        KeyboardShortcutModifier(shortcut: ghosttyShortcuts.keyboardShortcut(for: "start_search"))
      )
      .disabled(startSearchAction == nil)

      Button("Find Next") {
        navigateSearchNextAction?()
      }
      .modifier(
        KeyboardShortcutModifier(shortcut: ghosttyShortcuts.keyboardShortcut(for: "search:next"))
      )
      .disabled(navigateSearchNextAction == nil)

      Button("Find Previous") {
        navigateSearchPreviousAction?()
      }
      .modifier(
        KeyboardShortcutModifier(shortcut: ghosttyShortcuts.keyboardShortcut(for: "search:previous"))
      )
      .disabled(navigateSearchPreviousAction == nil)

      Divider()

      Button("Hide Find Bar") {
        endSearchAction?()
      }
      .modifier(
        KeyboardShortcutModifier(shortcut: ghosttyShortcuts.keyboardShortcut(for: "end_search"))
      )
      .disabled(endSearchAction == nil)

      Divider()

      Button("Use Selection for Find") {
        searchSelectionAction?()
      }
      .modifier(
        KeyboardShortcutModifier(shortcut: ghosttyShortcuts.keyboardShortcut(for: "search_selection"))
      )
      .disabled(searchSelectionAction == nil)
    }
  }
}

private struct StartSearchActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

extension FocusedValues {
  var startSearchAction: (() -> Void)? {
    get { self[StartSearchActionKey.self] }
    set { self[StartSearchActionKey.self] = newValue }
  }
}

private struct SearchSelectionActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

extension FocusedValues {
  var searchSelectionAction: (() -> Void)? {
    get { self[SearchSelectionActionKey.self] }
    set { self[SearchSelectionActionKey.self] = newValue }
  }
}

private struct NavigateSearchNextActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

extension FocusedValues {
  var navigateSearchNextAction: (() -> Void)? {
    get { self[NavigateSearchNextActionKey.self] }
    set { self[NavigateSearchNextActionKey.self] = newValue }
  }
}

private struct NavigateSearchPreviousActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

extension FocusedValues {
  var navigateSearchPreviousAction: (() -> Void)? {
    get { self[NavigateSearchPreviousActionKey.self] }
    set { self[NavigateSearchPreviousActionKey.self] = newValue }
  }
}

private struct EndSearchActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

extension FocusedValues {
  var endSearchAction: (() -> Void)? {
    get { self[EndSearchActionKey.self] }
    set { self[EndSearchActionKey.self] = newValue }
  }
}
