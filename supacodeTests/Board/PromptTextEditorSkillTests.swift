import Foundation
import Testing

@testable import Supacool

/// Coverage for the pure helpers behind the prompt editor's
/// slash-command UX: highlight scanning and the Ctrl-Space "reopen
/// at caret" lookup. The NSTextView side is left to manual /
/// integration testing — these helpers carry the actual logic.
@MainActor
struct PromptTextEditorSkillTests {
  // MARK: - Highlight scanning

  @Test func highlightsSingleClaudeCommandAtStart() {
    let ranges = PlaceholderTextView.skillHighlightRanges(
      in: "/changelog",
      trigger: "/",
      isValid: { $0 == "changelog" }
    )
    #expect(ranges == [NSRange(location: 0, length: 10)])
  }

  @Test func highlightsCommandAfterWhitespace() {
    let ranges = PlaceholderTextView.skillHighlightRanges(
      in: "fix bug then /lint please",
      trigger: "/",
      isValid: { $0 == "lint" }
    )
    #expect(ranges == [NSRange(location: 13, length: 5)])
  }

  @Test func skipsCommandInsideAWord() {
    // "foo/bar" — the slash is not at a token start, no highlight.
    let ranges = PlaceholderTextView.skillHighlightRanges(
      in: "foo/bar",
      trigger: "/",
      isValid: { _ in true }
    )
    #expect(ranges.isEmpty)
  }

  @Test func skipsUnknownCommands() {
    // The validator says "no" — nothing highlights even though the
    // syntax matches.
    let ranges = PlaceholderTextView.skillHighlightRanges(
      in: "/totally-unknown stuff",
      trigger: "/",
      isValid: { _ in false }
    )
    #expect(ranges.isEmpty)
  }

  @Test func highlightsMultipleCommandsInOnePrompt() {
    let valid: Set<String> = ["a", "b"]
    let ranges = PlaceholderTextView.skillHighlightRanges(
      in: "/a then /b",
      trigger: "/",
      isValid: { valid.contains($0) }
    )
    #expect(ranges == [
      NSRange(location: 0, length: 2),
      NSRange(location: 8, length: 2),
    ])
  }

  @Test func highlightsHyphenatedAndNamespacedNames() {
    let valid: Set<String> = ["check-ci", "compound-engineering:lfg"]
    let ranges = PlaceholderTextView.skillHighlightRanges(
      in: "/check-ci nightly /compound-engineering:lfg",
      trigger: "/",
      isValid: { valid.contains($0) }
    )
    #expect(ranges == [
      NSRange(location: 0, length: 9),
      NSRange(location: 18, length: 25),
    ])
  }

  @Test func usesAgentSpecificTriggerCharacter() {
    // Codex uses `$` instead of `/`. Same pure helper, different trigger.
    let ranges = PlaceholderTextView.skillHighlightRanges(
      in: "$peekaboo grab a screenshot",
      trigger: "$",
      isValid: { $0 == "peekaboo" }
    )
    #expect(ranges == [NSRange(location: 0, length: 9)])
  }

  @Test func emptyTextReturnsNoRanges() {
    let ranges = PlaceholderTextView.skillHighlightRanges(
      in: "",
      trigger: "/",
      isValid: { _ in true }
    )
    #expect(ranges.isEmpty)
  }

  @Test func loneTriggerWithoutNameDoesNotHighlight() {
    let ranges = PlaceholderTextView.skillHighlightRanges(
      in: "/ followed by space",
      trigger: "/",
      isValid: { _ in true }
    )
    #expect(ranges.isEmpty)
  }

  // MARK: - Ctrl-Space reopen

  @Test func reopensWhenCaretIsRightAfterTrigger() {
    let location = PlaceholderTextView.skillReopenTriggerLocation(
      in: "/foo",
      cursor: 4,
      trigger: "/"
    )
    #expect(location == 0)
  }

  @Test func reopensWhenCaretIsInsideTokenName() {
    // Cursor sitting in the middle of "/changelog" → trigger location is 0.
    let location = PlaceholderTextView.skillReopenTriggerLocation(
      in: "/changelog",
      cursor: 4,
      trigger: "/"
    )
    #expect(location == 0)
  }

  @Test func reopensFromMidPromptToken() {
    // "fix bug then /lint" — caret at end of "/lint".
    let location = PlaceholderTextView.skillReopenTriggerLocation(
      in: "fix bug then /lint",
      cursor: 18,
      trigger: "/"
    )
    #expect(location == 13)
  }

  @Test func skipsReopenWhenTriggerNotAtTokenStart() {
    // "foo/bar" — slash isn't at a token start (preceded by 'o').
    let location = PlaceholderTextView.skillReopenTriggerLocation(
      in: "foo/bar",
      cursor: 7,
      trigger: "/"
    )
    #expect(location == nil)
  }

  @Test func skipsReopenWhenCaretIsAfterWhitespace() {
    // "/changelog now" — caret after the space, no trigger to reopen.
    let location = PlaceholderTextView.skillReopenTriggerLocation(
      in: "/changelog now",
      cursor: 14,
      trigger: "/"
    )
    #expect(location == nil)
  }

  @Test func skipsReopenWhenCaretIsAtStartOfPlainText() {
    let location = PlaceholderTextView.skillReopenTriggerLocation(
      in: "hello",
      cursor: 0,
      trigger: "/"
    )
    #expect(location == nil)
  }

  @Test func reopenRespectsTriggerCharacterPerAgent() {
    // Codex uses `$`; reopen with `/` should fail on a `$`-prefixed token.
    let claudeAttempt = PlaceholderTextView.skillReopenTriggerLocation(
      in: "$peekaboo",
      cursor: 9,
      trigger: "/"
    )
    #expect(claudeAttempt == nil)

    let codexAttempt = PlaceholderTextView.skillReopenTriggerLocation(
      in: "$peekaboo",
      cursor: 9,
      trigger: "$"
    )
    #expect(codexAttempt == 0)
  }
}
