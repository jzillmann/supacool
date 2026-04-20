import AppKit
import SwiftUI

struct SkillAutocompleteConfig: Equatable, Sendable {
  let triggerCharacter: Character
}

struct SkillQuery: Equatable {
  let queryText: String
  let triggerCharacter: Character
  let triggerRange: NSRange
  let caretRect: CGRect

  static func == (lhs: SkillQuery, rhs: SkillQuery) -> Bool {
    lhs.queryText == rhs.queryText
      && lhs.triggerCharacter == rhs.triggerCharacter
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
  var editorHandle: PromptTextEditorHandle?
  var skillAutocomplete: SkillAutocompleteConfig?
  var onSkillQuery: ((SkillQuery?) -> Void)?
  var onSkillCommand: ((SkillAutocompleteCommand) -> Void)?
  /// Returns true when the given short name (without the trigger
  /// character) matches a known skill. The text view uses this to
  /// colorize completed `/<name>` / `$<name>` tokens in the prompt
  /// so the user can see at a glance which slash commands will
  /// actually fire.
  var skillValidator: ((String) -> Bool)?

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
    textView.skillAutocomplete = skillAutocomplete
    textView.skillValidator = skillValidator
    textView.onSkillQueryChange = context.coordinator.handleSkillQuery
    textView.onSkillCommand = context.coordinator.handleSkillCommand
    textView.applySkillHighlights()
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
    textView.skillAutocomplete = skillAutocomplete
    textView.onSkillQueryChange = context.coordinator.handleSkillQuery
    textView.onSkillCommand = context.coordinator.handleSkillCommand
    if textView.string != text {
      textView.string = text
    }
    if textView.placeholder != placeholder {
      textView.placeholder = placeholder
    }
    // Closures aren't equatable; reassign and re-render highlights every
    // update. Cheap for prompt-sized strings and ensures catalog reloads
    // (validator changes) repaint immediately.
    textView.skillValidator = skillValidator
    textView.applySkillHighlights()
    if skillAutocomplete == nil || onSkillQuery == nil {
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
    let triggerLocation: Int
    let triggerCharacter: Character
  }

  var placeholder: String = "" {
    didSet { needsDisplay = true }
  }
  var skillAutocomplete: SkillAutocompleteConfig? {
    didSet {
      guard skillAutocomplete != oldValue else { return }
      if skillAutocomplete == nil {
        cancelActiveSkillQuery()
      } else {
        reconcileSkillQuery()
      }
      applySkillHighlights()
    }
  }
  /// See `PromptTextEditor.skillValidator`. Set by the SwiftUI side on
  /// every update; closures aren't equatable so we don't gate on
  /// inequality. Calling `applySkillHighlights()` re-paints from the
  /// current value — idempotent.
  var skillValidator: ((String) -> Bool)?
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
    applySkillHighlights()
    needsDisplay = true
  }

  override func insertText(_ insertString: Any, replacementRange: NSRange) {
    let insertedText = Self.plainString(from: insertString)
    let resolvedRange = resolvedReplacementRange(replacementRange)
    let triggerCharacter = skillTriggerCharacter(
      insertedText: insertedText,
      replacementRange: resolvedRange
    )

    super.insertText(insertString, replacementRange: replacementRange)

    if let triggerCharacter {
      activeSkillState = ActiveSkillState(
        triggerLocation: resolvedRange.location,
        triggerCharacter: triggerCharacter
      )
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
    guard skillAutocomplete?.triggerCharacter == activeSkillState.triggerCharacter else {
      cancelActiveSkillQuery()
      return
    }

    let selection = selectedRange()
    guard selection.length == 0 else {
      cancelActiveSkillQuery()
      return
    }
    guard selection.location > activeSkillState.triggerLocation else {
      cancelActiveSkillQuery()
      return
    }

    let content = string as NSString
    guard activeSkillState.triggerLocation < content.length else {
      cancelActiveSkillQuery()
      return
    }
    let triggerString = String(activeSkillState.triggerCharacter)
    guard content.substring(with: NSRange(location: activeSkillState.triggerLocation, length: 1)) == triggerString else {
      cancelActiveSkillQuery()
      return
    }

    let queryRange = NSRange(
      location: activeSkillState.triggerLocation + 1,
      length: selection.location - activeSkillState.triggerLocation - 1
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
      location: activeSkillState.triggerLocation,
      length: selection.location - activeSkillState.triggerLocation
    )
    onSkillQueryChange?(
      SkillQuery(
        queryText: queryText,
        triggerCharacter: activeSkillState.triggerCharacter,
        triggerRange: triggerRange,
        caretRect: caretRect(at: selection.location)
      )
    )
  }

  func cancelActiveSkillQuery() {
    activeSkillState = nil
    onSkillQueryChange?(nil)
  }

  /// Repaint accent-color highlights over every `<trigger><name>` token
  /// in the prompt that resolves to a known skill. Idempotent — clears
  /// existing color first, then reapplies. Called on text change, on
  /// validator/config changes, and after programmatic insertions.
  func applySkillHighlights() {
    guard let textStorage else { return }
    let fullRange = NSRange(location: 0, length: textStorage.length)
    textStorage.beginEditing()
    defer { textStorage.endEditing() }
    textStorage.removeAttribute(.foregroundColor, range: fullRange)
    guard let trigger = skillAutocomplete?.triggerCharacter,
      let validator = skillValidator,
      textStorage.length > 0
    else { return }

    let content = textStorage.string as NSString
    let triggerString = String(trigger)
    var cursor = 0
    while cursor < content.length {
      let searchRange = NSRange(location: cursor, length: content.length - cursor)
      let triggerRange = content.range(of: triggerString, options: [], range: searchRange)
      guard triggerRange.location != NSNotFound else { return }

      let isAtTokenStart: Bool = {
        guard triggerRange.location > 0 else { return true }
        let prev = content.substring(with: NSRange(location: triggerRange.location - 1, length: 1))
        return prev.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
      }()

      guard isAtTokenStart else {
        cursor = triggerRange.location + 1
        continue
      }

      var nameEnd = triggerRange.location + 1
      while nameEnd < content.length {
        let next = content.substring(with: NSRange(location: nameEnd, length: 1))
        guard Self.isSkillNameCharacter(next) else { break }
        nameEnd += 1
      }
      let nameLength = nameEnd - triggerRange.location - 1
      if nameLength > 0 {
        let name = content.substring(
          with: NSRange(location: triggerRange.location + 1, length: nameLength)
        )
        if validator(name) {
          let highlightRange = NSRange(
            location: triggerRange.location,
            length: nameLength + 1
          )
          textStorage.addAttribute(
            .foregroundColor,
            value: NSColor.controlAccentColor,
            range: highlightRange
          )
        }
      }
      cursor = max(nameEnd, triggerRange.location + 1)
    }
  }

  private static let skillNameAllowedScalars: CharacterSet = {
    var set = CharacterSet.alphanumerics
    set.insert(charactersIn: "-_:")
    return set
  }()

  private static func isSkillNameCharacter(_ substring: String) -> Bool {
    guard substring.unicodeScalars.count == 1, let scalar = substring.unicodeScalars.first else {
      return false
    }
    return skillNameAllowedScalars.contains(scalar)
  }

  func commitActiveSkill(_ replacement: String) {
    guard let activeSkillState else { return }
    let selection = selectedRange()
    guard selection.length == 0 else { return }
    guard selection.location >= activeSkillState.triggerLocation else { return }

    let triggerRange = NSRange(
      location: activeSkillState.triggerLocation,
      length: selection.location - activeSkillState.triggerLocation
    )
    guard shouldChangeText(in: triggerRange, replacementString: replacement) else { return }

    textStorage?.replaceCharacters(in: triggerRange, with: replacement)
    didChangeText()

    let cursorLocation = activeSkillState.triggerLocation + (replacement as NSString).length
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
    guard activeSkillState != nil, skillAutocomplete != nil, onSkillQueryChange != nil else { return false }
    onSkillCommand?(command)
    return true
  }

  private func skillTriggerCharacter(insertedText: String?, replacementRange: NSRange) -> Character? {
    guard let skillAutocomplete else { return nil }
    guard onSkillQueryChange != nil else { return nil }
    guard activeSkillState == nil else { return nil }
    guard insertedText == String(skillAutocomplete.triggerCharacter) else { return nil }
    guard replacementRange.length == 0 else { return nil }

    let insertionLocation = replacementRange.location
    guard insertionLocation != NSNotFound else { return nil }
    guard insertionLocation > 0 else { return skillAutocomplete.triggerCharacter }

    let content = string as NSString
    guard insertionLocation - 1 < content.length else { return nil }
    let previousCharacter = content.substring(with: NSRange(location: insertionLocation - 1, length: 1))
    guard previousCharacter.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) else {
      return nil
    }
    return skillAutocomplete.triggerCharacter
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
