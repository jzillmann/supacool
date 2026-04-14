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
  var placeholder: String = ""
  var autoFocus: Bool = true

  /// The NSTextView's text container inset. Exposed so callers that need
  /// to align other chrome to the first glyph can use the same numbers.
  static let inset = NSSize(width: 5, height: 6)

  func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

  func makeNSView(context: Context) -> NSScrollView {
    let textView = PlaceholderTextView(frame: .zero)
    textView.placeholder = placeholder
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
    guard let textView = nsView.documentView as? PlaceholderTextView else { return }
    if textView.string != text {
      textView.string = text
    }
    if textView.placeholder != placeholder {
      textView.placeholder = placeholder
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

/// NSTextView that draws a placeholder string when empty. Because the
/// placeholder is drawn by the text view itself, it shares the exact
/// same glyph origin as real text — no ZStack alignment fudging needed.
final class PlaceholderTextView: NSTextView {
  var placeholder: String = "" {
    didSet { needsDisplay = true }
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard string.isEmpty, !placeholder.isEmpty else { return }
    let attrs: [NSAttributedString.Key: Any] = [
      .font: font ?? NSFont.preferredFont(forTextStyle: .body),
      .foregroundColor: NSColor.tertiaryLabelColor,
    ]
    let placeholderString = NSAttributedString(string: placeholder, attributes: attrs)
    placeholderString.draw(
      with: placeholderRect,
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      context: nil
    )
  }

  override func didChangeText() {
    super.didChangeText()
    needsDisplay = true
  }

  private var placeholderRect: NSRect {
    guard let textContainer else {
      return NSRect(origin: textContainerOrigin, size: bounds.size)
    }

    let origin = textContainerOrigin
    let lineFragmentPadding = textContainer.lineFragmentPadding
    let horizontalInset = origin.x + lineFragmentPadding
    let width = max(bounds.width - (horizontalInset * 2), 0)
    let height = max(bounds.height - origin.y, 0)

    return NSRect(
      x: horizontalInset,
      y: origin.y,
      width: width,
      height: height
    )
  }
}
