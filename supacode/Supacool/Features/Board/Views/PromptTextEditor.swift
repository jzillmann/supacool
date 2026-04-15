import AppKit
import SwiftUI

struct SkillQuery: Equatable {
  let queryText: String
  let triggerRange: NSRange
  let caretRect: CGRect

  static func == (lhs: SkillQuery, rhs: SkillQuery) -> Bool {
    lhs.queryText == rhs.queryText
      && NSEqualRanges(lhs.triggerRange, rhs.triggerRange)
      && lhs.caretRect == rhs.caretRect
  }
}

nonisolated enum SkillAutocompleteCommand: Equatable, Sendable {
  case moveSelection(Int)
  case commitSelection
  case dismiss
}

@MainActor
final class PromptTextEditorHandle {
  fileprivate weak var textView: PlaceholderTextView?

  func commitSkill(_ replacement: String) {
    textView?.commitActiveSkill(replacement)
  }
}

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
  var editorHandle: PromptTextEditorHandle? = nil
  var onSkillQuery: ((SkillQuery?) -> Void)? = nil
  var onSkillCommand: ((SkillAutocompleteCommand) -> Void)? = nil

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
    textView.onSkillQueryChange = context.coordinator.handleSkillQuery
    textView.onSkillCommand = context.coordinator.handleSkillCommand
    context.coordinator.bind(textView, handle: editorHandle)

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
    context.coordinator.onSkillQuery = onSkillQuery
    context.coordinator.onSkillCommand = onSkillCommand
    context.coordinator.bind(textView, handle: editorHandle)
    textView.onSkillQueryChange = context.coordinator.handleSkillQuery
    textView.onSkillCommand = context.coordinator.handleSkillCommand
    if textView.string != text {
      textView.string = text
    }
    if textView.placeholder != placeholder {
      textView.placeholder = placeholder
    }
    if onSkillQuery == nil {
      textView.cancelActiveSkillQuery()
    } else {
      textView.reconcileSkillQuery()
    }
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    @Binding var text: String
    var onSkillQuery: ((SkillQuery?) -> Void)?
    var onSkillCommand: ((SkillAutocompleteCommand) -> Void)?

    init(text: Binding<String>) { _text = text }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      text = textView.string
    }

    func textViewDidChangeSelection(_ notification: Notification) {
      guard let textView = notification.object as? PlaceholderTextView else { return }
      textView.reconcileSkillQuery()
    }

    func bind(_ textView: PlaceholderTextView, handle: PromptTextEditorHandle?) {
      handle?.textView = textView
    }

    func handleSkillQuery(_ query: SkillQuery?) {
      onSkillQuery?(query)
    }

    func handleSkillCommand(_ command: SkillAutocompleteCommand) {
      onSkillCommand?(command)
    }
  }
}

/// NSTextView that draws a placeholder string when empty. Because the
/// placeholder is drawn by the text view itself, it shares the exact
/// same glyph origin as real text — no ZStack alignment fudging needed.
final class PlaceholderTextView: NSTextView {
  private struct ActiveSkillState {
    let slashLocation: Int
  }

  var placeholder: String = "" {
    didSet { needsDisplay = true }
  }
  var onSkillQueryChange: ((SkillQuery?) -> Void)?
  var onSkillCommand: ((SkillAutocompleteCommand) -> Void)?

  private var activeSkillState: ActiveSkillState?

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

  override func insertText(_ insertString: Any, replacementRange: NSRange) {
    let insertedText = Self.plainString(from: insertString)
    let resolvedRange = resolvedReplacementRange(replacementRange)
    let shouldStartSkillQuery = shouldStartSkillQuery(
      insertedText: insertedText,
      replacementRange: resolvedRange
    )

    super.insertText(insertString, replacementRange: replacementRange)

    if shouldStartSkillQuery {
      activeSkillState = ActiveSkillState(slashLocation: resolvedRange.location)
    }
    if activeSkillState != nil {
      reconcileSkillQuery()
    }
  }

  override func deleteBackward(_ sender: Any?) {
    super.deleteBackward(sender)
    if activeSkillState != nil {
      reconcileSkillQuery()
    }
  }

  override func deleteForward(_ sender: Any?) {
    super.deleteForward(sender)
    if activeSkillState != nil {
      reconcileSkillQuery()
    }
  }

  override func moveUp(_ sender: Any?) {
    guard !dispatchSkillCommand(.moveSelection(-1)) else { return }
    super.moveUp(sender)
  }

  override func moveDown(_ sender: Any?) {
    guard !dispatchSkillCommand(.moveSelection(+1)) else { return }
    super.moveDown(sender)
  }

  override func insertNewline(_ sender: Any?) {
    guard !dispatchSkillCommand(.commitSelection) else { return }
    super.insertNewline(sender)
  }

  override func insertTab(_ sender: Any?) {
    guard !dispatchSkillCommand(.commitSelection) else { return }
    super.insertTab(sender)
  }

  override func cancelOperation(_ sender: Any?) {
    guard !dispatchSkillCommand(.dismiss) else { return }
    super.cancelOperation(sender)
  }

  func reconcileSkillQuery() {
    guard onSkillQueryChange != nil else {
      cancelActiveSkillQuery()
      return
    }
    guard let activeSkillState else { return }

    let selection = selectedRange()
    guard selection.length == 0 else {
      cancelActiveSkillQuery()
      return
    }
    guard selection.location > activeSkillState.slashLocation else {
      cancelActiveSkillQuery()
      return
    }

    let content = string as NSString
    guard activeSkillState.slashLocation < content.length else {
      cancelActiveSkillQuery()
      return
    }
    guard content.substring(with: NSRange(location: activeSkillState.slashLocation, length: 1)) == "/" else {
      cancelActiveSkillQuery()
      return
    }

    let queryRange = NSRange(
      location: activeSkillState.slashLocation + 1,
      length: selection.location - activeSkillState.slashLocation - 1
    )
    guard queryRange.location <= content.length, NSMaxRange(queryRange) <= content.length else {
      cancelActiveSkillQuery()
      return
    }

    let queryText = content.substring(with: queryRange)
    guard !queryText.contains(where: \.isWhitespace) else {
      cancelActiveSkillQuery()
      return
    }

    let triggerRange = NSRange(
      location: activeSkillState.slashLocation,
      length: selection.location - activeSkillState.slashLocation
    )
    onSkillQueryChange?(
      SkillQuery(
        queryText: queryText,
        triggerRange: triggerRange,
        caretRect: caretRect(at: selection.location)
      )
    )
  }

  func cancelActiveSkillQuery() {
    activeSkillState = nil
    onSkillQueryChange?(nil)
  }

  func commitActiveSkill(_ replacement: String) {
    guard let activeSkillState else { return }
    let selection = selectedRange()
    guard selection.length == 0 else { return }
    guard selection.location >= activeSkillState.slashLocation else { return }

    let triggerRange = NSRange(
      location: activeSkillState.slashLocation,
      length: selection.location - activeSkillState.slashLocation
    )
    guard shouldChangeText(in: triggerRange, replacementString: replacement) else { return }

    textStorage?.replaceCharacters(in: triggerRange, with: replacement)
    didChangeText()

    let cursorLocation = activeSkillState.slashLocation + (replacement as NSString).length
    setSelectedRange(NSRange(location: cursorLocation, length: 0))
    window?.makeFirstResponder(self)
    cancelActiveSkillQuery()
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

  private func dispatchSkillCommand(_ command: SkillAutocompleteCommand) -> Bool {
    guard activeSkillState != nil, onSkillQueryChange != nil else { return false }
    onSkillCommand?(command)
    return true
  }

  private func shouldStartSkillQuery(insertedText: String?, replacementRange: NSRange) -> Bool {
    guard onSkillQueryChange != nil else { return false }
    guard activeSkillState == nil else { return false }
    guard insertedText == "/" else { return false }
    guard replacementRange.length == 0 else { return false }

    let insertionLocation = replacementRange.location
    guard insertionLocation != NSNotFound else { return false }
    guard insertionLocation > 0 else { return true }

    let content = string as NSString
    guard insertionLocation - 1 < content.length else { return false }
    let previousCharacter = content.substring(with: NSRange(location: insertionLocation - 1, length: 1))
    return previousCharacter.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
  }

  private func resolvedReplacementRange(_ replacementRange: NSRange) -> NSRange {
    replacementRange.location == NSNotFound ? selectedRange() : replacementRange
  }

  private func caretRect(at location: Int) -> CGRect {
    let characterRange = NSRange(location: location, length: 0)
    let screenRect = firstRect(forCharacterRange: characterRange, actualRange: nil)
    guard let window, let contentView = enclosingScrollView?.contentView else {
      return .zero
    }

    let windowRect = window.convertFromScreen(screenRect)
    let localRect = contentView.convert(windowRect, from: nil)
    let topAlignedY = max(contentView.bounds.height - localRect.maxY, 0)

    return CGRect(
      x: max(localRect.minX, 0),
      y: topAlignedY,
      width: localRect.width,
      height: localRect.height
    )
  }

  private static func plainString(from value: Any) -> String? {
    switch value {
    case let string as String:
      return string
    case let attributed as NSAttributedString:
      return attributed.string
    default:
      return nil
    }
  }
}
