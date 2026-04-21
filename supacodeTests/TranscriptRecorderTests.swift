import Foundation
import Testing

@testable import Supacool

/// Pure-function tests for the transcript recording pipeline. The
/// disk-writing parts of `TranscriptRecorder` are validated manually via
/// the smoke test described in the plan; here we lock in the shape of
/// the data model and the delta computation.
struct TranscriptRecorderTests {
  // MARK: - TranscriptDelta

  @Test func deltaFromEmptyReturnsEverything() {
    #expect(TranscriptDelta.compute(previous: "", next: "hello world") == "hello world")
  }

  @Test func deltaWhenAppendOnlyReturnsSuffix() {
    #expect(
      TranscriptDelta.compute(
        previous: "claude>\n",
        next: "claude>\nrunning your prompt\n"
      ) == "running your prompt\n"
    )
  }

  @Test func deltaWhenIdenticalIsEmpty() {
    #expect(TranscriptDelta.compute(previous: "no change\n", next: "no change\n") == "")
  }

  @Test func deltaWhenScrollbackTrimmedFallsBackToFullNext() {
    // Simulates the scrollback being trimmed at the top — `previous`'s
    // first chars no longer appear at the start of `next`. We re-emit the
    // full `next` rather than try to realign — better to over-capture than
    // silently drop content.
    let next = "trimmed-leading\nnewer content\n"
    #expect(TranscriptDelta.compute(previous: "older content", next: next) == next)
  }

  @Test func deltaIsUnicodeSafe() {
    let previous = "👋 hi"
    let next = "👋 hi 🎉"
    #expect(TranscriptDelta.compute(previous: previous, next: next) == " 🎉")
  }

  // MARK: - TranscriptEntry Codable round-trip

  @Test func inputEntryRoundTrips() throws {
    let original = TranscriptEntry.input(
      text: "ls -la\n",
      at: Date(timeIntervalSinceReferenceDate: 100)
    )
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(TranscriptEntry.self, from: data)
    #expect(decoded == original)
  }

  @Test func outputTurnEntryRoundTrips() throws {
    let original = TranscriptEntry.outputTurn(
      fullText: "claude>\nresponse here\n",
      delta: "response here\n",
      at: Date(timeIntervalSinceReferenceDate: 200)
    )
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(TranscriptEntry.self, from: data)
    #expect(decoded == original)
  }

  @Test func decodingMissingOptionalFieldsUsesDefaults() throws {
    // Forward-compat: a transcript file written by a future version that
    // dropped one of the optional payload fields should still decode (with
    // the field defaulted) rather than failing the whole row. Mirrors the
    // `decodeIfPresent` pattern used everywhere in the project.
    let payload = #"{"kind":"input"}"#.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(TranscriptEntry.self, from: payload)
    if case .input(let text, _) = decoded {
      #expect(text == "")
    } else {
      Issue.record("Expected .input case, got \(decoded)")
    }
  }

  @Test func decodingUnknownKindThrows() {
    let payload = #"{"kind":"unknownFutureKind"}"#.data(using: .utf8)!
    #expect(throws: DecodingError.self) {
      _ = try JSONDecoder().decode(TranscriptEntry.self, from: payload)
    }
  }

  @Test func entryTimestampReturnsThePayloadDate() {
    let now = Date(timeIntervalSinceReferenceDate: 500)
    let input = TranscriptEntry.input(text: "x", at: now)
    let output = TranscriptEntry.outputTurn(fullText: "x", delta: "x", at: now)
    #expect(input.timestamp == now)
    #expect(output.timestamp == now)
  }
}
