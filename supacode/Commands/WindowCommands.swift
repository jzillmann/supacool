import SwiftUI

// ⌘W is claimed here only as the *fallback* meaning — "close the front window"
// — for when nothing nearer to the user's focus wants it. The full-screen
// session view binds its own ⌘W ("back to the board") on a view, and AppKit
// offers key equivalents to the key window's view hierarchy before the main
// menu, so that one wins whenever a session is open. Ghostty never sees ⌘W at
// all: `AppShortcuts.reservedGhosttyUnbindArguments` unbinds it at launch.
struct WindowCommands: Commands {
  var body: some Commands {
    CommandGroup(replacing: .saveItem) {
      Button("Close Window", systemImage: "xmark") {
        (NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow)?.performClose(nil)
      }
      .keyboardShortcut("w")
      .help("Close the front window (⌘W)")
    }
  }
}

struct KeyboardShortcutModifier: ViewModifier {
  let shortcut: KeyboardShortcut?

  func body(content: Content) -> some View {
    if let shortcut {
      content.keyboardShortcut(shortcut)
    } else {
      content
    }
  }
}
