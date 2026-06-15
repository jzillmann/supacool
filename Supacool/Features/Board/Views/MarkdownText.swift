import SwiftUI

/// Block structure recognized by `MarkdownText`. SwiftUI's `Text` only
/// interprets *inline* markdown (bold, italic, links, `code`), so headings,
/// list items, quotes, and fenced code have to be split out beforehand —
/// this enum is that pre-pass, kept `nonisolated` so it stays unit-testable.
nonisolated enum MarkdownBlock: Equatable {
  case heading(level: Int, text: String)
  case bullet(indent: Int, text: String)
  case ordered(indent: Int, number: String, text: String)
  case quote(text: String)
  case code(text: String)
  case paragraph(text: String)
  case blank

  /// Splits a markdown document into renderable blocks, line by line.
  /// Consecutive blank lines collapse into a single `.blank` spacer so
  /// generous source spacing doesn't balloon the rendered height.
  static func parse(_ source: String) -> [MarkdownBlock] {
    var blocks: [MarkdownBlock] = []
    var codeLines: [String]?

    for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = String(rawLine)
      let trimmed = line.trimmingCharacters(in: .whitespaces)

      if trimmed.hasPrefix("```") {
        if let lines = codeLines {
          blocks.append(.code(text: lines.joined(separator: "\n")))
          codeLines = nil
        } else {
          codeLines = []
        }
        continue
      }
      if codeLines != nil {
        codeLines?.append(line)
        continue
      }

      if trimmed.isEmpty {
        if blocks.last != .blank, !blocks.isEmpty {
          blocks.append(.blank)
        }
        continue
      }

      blocks.append(block(line: line, trimmed: trimmed))
    }

    // An unterminated fence still renders as code rather than vanishing.
    if let lines = codeLines {
      blocks.append(.code(text: lines.joined(separator: "\n")))
    }
    if blocks.last == .blank {
      blocks.removeLast()
    }
    return blocks
  }

  private static func block(line: String, trimmed: String) -> MarkdownBlock {
    let indent = line.prefix(while: { $0 == " " }).count / 2

    if let level = headingLevel(trimmed) {
      let text = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
      return .heading(level: level, text: text)
    }
    if trimmed.count >= 2, "-*+".contains(trimmed.first!), trimmed[trimmed.index(after: trimmed.startIndex)] == " " {
      return .bullet(indent: indent, text: String(trimmed.dropFirst(2)))
    }
    if let match = trimmed.firstMatch(of: /^(\d{1,3})[.)] +(.*)$/) {
      return .ordered(indent: indent, number: String(match.1), text: String(match.2))
    }
    if trimmed.hasPrefix(">") {
      return .quote(text: trimmed.dropFirst().trimmingCharacters(in: .whitespaces))
    }
    return .paragraph(text: trimmed)
  }

  private static func headingLevel(_ trimmed: String) -> Int? {
    let hashes = trimmed.prefix(while: { $0 == "#" }).count
    guard (1...6).contains(hashes), trimmed.dropFirst(hashes).first == " " else { return nil }
    return hashes
  }
}

/// Renders a markdown document (e.g. a Linear ticket description) as styled
/// SwiftUI views: block layout from `MarkdownBlock`, inline spans (bold,
/// links, `code`) via `AttributedString`, so links stay tappable.
struct MarkdownText: View {
  let source: String

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(Array(MarkdownBlock.parse(source).enumerated()), id: \.offset) { _, block in
        view(for: block)
      }
    }
  }

  @ViewBuilder
  private func view(for block: MarkdownBlock) -> some View {
    switch block {
    case .heading(let level, let text):
      Text(inline(text))
        .font(headingFont(level))
        .foregroundStyle(.primary)
        .padding(.top, 2)
    case .bullet(let indent, let text):
      listRow(marker: "•", indent: indent, text: text)
    case .ordered(let indent, let number, let text):
      listRow(marker: "\(number).", indent: indent, text: text)
    case .quote(let text):
      Text(inline(text))
        .italic()
        .padding(.leading, 8)
        .overlay(alignment: .leading) {
          RoundedRectangle(cornerRadius: 1)
            .fill(.quaternary)
            .frame(width: 3)
        }
    case .code(let text):
      Text(verbatim: text)
        .font(.callout.monospaced())
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
    case .paragraph(let text):
      Text(inline(text))
    case .blank:
      Color.clear.frame(height: 2)
    }
  }

  private func listRow(marker: String, indent: Int, text: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text(marker)
        .foregroundStyle(.tertiary)
      Text(inline(text))
    }
    .padding(.leading, CGFloat(indent) * 12)
  }

  private func headingFont(_ level: Int) -> Font {
    switch level {
    case 1: return .headline
    case 2: return .subheadline.weight(.semibold)
    default: return .callout.weight(.semibold)
    }
  }

  private func inline(_ text: String) -> AttributedString {
    (try? AttributedString(
      markdown: text,
      options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    )) ?? AttributedString(text)
  }
}
