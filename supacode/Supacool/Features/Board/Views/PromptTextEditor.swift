import AppKit
import SwiftUI

/// A multi-line text editor for prompts with **known** text-container
/// insets, so placeholders/cursors align predictably, and optional
/// auto-focus on first display.
///
/// Mirrors supacode's `PlainTextEditor` but exposes `textContainerInset`
/// as static knowledge (`inset`), and focuses the text view in the
/// window on appear if `autoFocus == true`. This is the right tool for
/// sheet-first text fields where SwiftUI's `TextEditor` doesn't give us
/// precise alignment control.
struct PromptTextEditor: NSViewRepresentable {
  @Binding var text: String
  var autoFocus: Bool = true

  /// The NSTextView's text container inset. Placeholder views in ZStack
  /// over this editor should pad by these exact values to align the
  /// placeholder with the cursor / first glyph.
  static let inset = NSSize(width: 5, height: 6)

  func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

  func makeNSView(context: Context) -> NSScrollView {
    let textView = NSTextView(frame: .zero)
    textView.delegate = context.coordinator
    textView.drawsBackground = false
    textView.isRichText = false
    textView.importsGraphics = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.font = NSFont.preferredFont(forTextStyle: .body)
    textView.textContainerInset = Self.inset
    textView.minSize = NSSize(width: 0, height: 0)
    textView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude,
      height: CGFloat.greatestFiniteMagnitude
    )
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.textContainer?.containerSize = NSSize(
      width: 0,
      height: CGFloat.greatestFiniteMagnitude
    )
    textView.textContainer?.lineFragmentPadding = 0
    textView.textContainer?.widthTracksTextView = true
    textView.string = text

    let scrollView = NSScrollView(frame: .zero)
    scrollView.drawsBackground = false
    scrollView.borderType = .noBorder
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.documentView = textView

    if autoFocus {
      // Defer to the next runloop so the view is attached to a window.
      DispatchQueue.main.async { [weak textView] in
        textView?.window?.makeFirstResponder(textView)
      }
    }
    return scrollView
  }

  func updateNSView(_ nsView: NSScrollView, context: Context) {
    guard let textView = nsView.documentView as? NSTextView else { return }
    if textView.string != text {
      textView.string = text
    }
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    @Binding var text: String
    init(text: Binding<String>) { _text = text }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      text = textView.string
    }
  }
}
