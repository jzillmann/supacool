import AppKit

/// Ghostty's paste protection asks the embedder to confirm a paste that could run
/// commands (newlines, control characters) when the running program has not enabled
/// bracketed paste. Ghostty's own app shows a sheet; this is Supacool's equivalent.
enum PasteConfirmationAlert {
  static func present(text: String, completion: @escaping @Sendable @MainActor (Bool) -> Void) {
    // Same as UntrustedURLAlert: the request arrives from inside a core callback,
    // so present on the next main-loop turn.
    DispatchQueue.main.async {
      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.icon = NSImage(named: NSImage.cautionName)
      alert.messageText = "Paste Potentially Unsafe Text?"
      alert.informativeText = """
        This text may run commands as soon as it is pasted. Only continue if you \
        trust it.
        """
      alert.accessoryView = UntrustedURLAlert.targetView(text)
      // Cancel is deliberately the default action.
      alert.addButton(withTitle: "Cancel")
      alert.addButton(withTitle: "Paste")
      UntrustedURLAlert.present(alert) { completion($0 == .alertSecondButtonReturn) }
    }
  }
}
