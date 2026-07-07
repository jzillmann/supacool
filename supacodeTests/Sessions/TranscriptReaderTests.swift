import Foundation
import Testing

@testable import Supacool

struct TranscriptReaderTests {
  // MARK: - aggregatePrompts

  @Test func groupsAdjacentKeystrokesIntoSinglePrompt() {
    let start = Date(timeIntervalSinceReferenceDate: 100)
    let entries: [TranscriptEntry] = [
      .input(text: "h", at: start),
      .input(text: "e", at: start.addingTimeInterval(0.1)),
      .input(text: "l", at: start.addingTimeInterval(0.2)),
      .input(text: "l", at: start.addingTimeInterval(0.3)),
      .input(text: "o", at: start.addingTimeInterval(0.4)),
    ]
    let prompts = TranscriptReader.aggregatePrompts(from: entries)
    #expect(prompts.count == 1)
    #expect(prompts.first?.text == "hello")
  }

  @Test func splitsPromptsOnIdleGap() {
    let start = Date(timeIntervalSinceReferenceDate: 100)
    let entries: [TranscriptEntry] = [
      .input(text: "first", at: start),
      .input(text: "more", at: start.addingTimeInterval(0.3)),
      // 10-second gap — new prompt.
      .input(text: "second", at: start.addingTimeInterval(10.5)),
      .input(text: "tail", at: start.addingTimeInterval(10.8)),
    ]
    let prompts = TranscriptReader.aggregatePrompts(from: entries)
    #expect(prompts.count == 2)
    // Reversed — newest first.
    #expect(prompts[0].text == "secondtail")
    #expect(prompts[1].text == "firstmore")
  }

  @Test func dropsPromptsBelowMinimumLength() {
    let start = Date(timeIntervalSinceReferenceDate: 100)
    let entries: [TranscriptEntry] = [
      .input(text: "y", at: start),  // too short — probably a y/n reply
      .input(text: "big prompt here", at: start.addingTimeInterval(5.0)),
    ]
    let prompts = TranscriptReader.aggregatePrompts(from: entries)
    #expect(prompts.count == 1)
    #expect(prompts.first?.text == "big prompt here")
  }

  @Test func trimsWhitespaceBeforeComparingToMinimum() {
    let start = Date(timeIntervalSinceReferenceDate: 100)
    let entries: [TranscriptEntry] = [
      // All whitespace — should be treated as empty, dropped.
      .input(text: "   \t  ", at: start),
      .input(text: "real prompt", at: start.addingTimeInterval(5.0)),
    ]
    let prompts = TranscriptReader.aggregatePrompts(from: entries)
    #expect(prompts.count == 1)
    #expect(prompts.first?.text == "real prompt")
  }

  @Test func ignoresOutputTurnEntries() {
    let start = Date(timeIntervalSinceReferenceDate: 100)
    let entries: [TranscriptEntry] = [
      .input(text: "hello world", at: start),
      .outputTurn(fullText: "a lot of terminal content", delta: "delta", at: start.addingTimeInterval(1)),
      .input(text: "second prompt", at: start.addingTimeInterval(10.0)),
    ]
    let prompts = TranscriptReader.aggregatePrompts(from: entries)
    #expect(prompts.count == 2)
    #expect(prompts.map(\.text) == ["second prompt", "hello world"])
  }

  @Test func emptyEntriesYieldEmptyPromptList() {
    #expect(TranscriptReader.aggregatePrompts(from: []) == [])
  }

  @Test func customIdleBreakIsRespected() {
    let start = Date(timeIntervalSinceReferenceDate: 100)
    let entries: [TranscriptEntry] = [
      .input(text: "first", at: start),
      .input(text: "still same", at: start.addingTimeInterval(3.0)),
    ]
    // With default 2s break the 3s gap would split. Override to 5s so
    // both land in the same bucket — exercises the idleBreak param.
    let prompts = TranscriptReader.aggregatePrompts(from: entries, idleBreak: 5.0)
    #expect(prompts.count == 1)
    #expect(prompts.first?.text == "firststill same")
  }
}
