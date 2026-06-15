import Testing

@testable import Supacool

struct MarkdownBlockTests {
  @Test func headingsBulletsAndParagraphs() {
    let source = """
      ## Steps to Reproduce

      * Open the syncs list
      * Observe the total runs

      **Actual Result:** counts mismatch.
      """

    #expect(
      MarkdownBlock.parse(source) == [
        .heading(level: 2, text: "Steps to Reproduce"),
        .blank,
        .bullet(indent: 0, text: "Open the syncs list"),
        .bullet(indent: 0, text: "Observe the total runs"),
        .blank,
        .paragraph(text: "**Actual Result:** counts mismatch."),
      ]
    )
  }

  @Test func orderedListsKeepTheirNumbers() {
    #expect(
      MarkdownBlock.parse("1. first\n2) second") == [
        .ordered(indent: 0, number: "1", text: "first"),
        .ordered(indent: 0, number: "2", text: "second"),
      ]
    )
  }

  @Test func nestedBulletsCarryIndentLevel() {
    #expect(
      MarkdownBlock.parse("- top\n  - nested") == [
        .bullet(indent: 0, text: "top"),
        .bullet(indent: 1, text: "nested"),
      ]
    )
  }

  @Test func boldLineIsNotMistakenForABullet() {
    #expect(MarkdownBlock.parse("**bold lead-in** text") == [.paragraph(text: "**bold lead-in** text")])
  }

  @Test func fencedCodeIsKeptVerbatim() {
    let source = """
      before
      ```
      let x = 1
      # not a heading
      ```
      after
      """

    #expect(
      MarkdownBlock.parse(source) == [
        .paragraph(text: "before"),
        .code(text: "let x = 1\n# not a heading"),
        .paragraph(text: "after"),
      ]
    )
  }

  @Test func unterminatedFenceStillRendersAsCode() {
    #expect(
      MarkdownBlock.parse("```\norphan") == [
        .code(text: "orphan"),
      ]
    )
  }

  @Test func blankLinesCollapseAndTrim() {
    #expect(
      MarkdownBlock.parse("\n\na\n\n\nb\n\n") == [
        .paragraph(text: "a"),
        .blank,
        .paragraph(text: "b"),
      ]
    )
  }

  @Test func quotesAndDeepHeadings() {
    #expect(
      MarkdownBlock.parse("> quoted\n### h3\n####### too deep") == [
        .quote(text: "quoted"),
        .heading(level: 3, text: "h3"),
        .paragraph(text: "####### too deep"),
      ]
    )
  }
}
