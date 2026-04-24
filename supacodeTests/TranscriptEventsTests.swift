import Foundation
import Testing

@testable import Supacool

/// Round-trip + forward-compat tests for the structured event kinds added
/// to `TranscriptEntry`. Each case must survive encode→decode without data
/// loss, and a reader pointed at a file with fields missing must still
/// succeed (per `docs/agent-guides/persistence.md` — synthesized Codable
/// silently wipes data on schema changes, so every field uses
/// `decodeIfPresent ?? default`).
struct TranscriptEventsTests {
  private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
  private let surfaceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

  private var encoder: JSONEncoder {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    return e
  }

  private var decoder: JSONDecoder {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
  }

  // MARK: - Round-trip per case

  @Test func hookBusyRoundTrips() throws {
    let entry = TranscriptEntry.hookBusy(active: true, pid: 4242, surfaceID: surfaceID, at: fixedDate)
    let decoded = try decoder.decode(TranscriptEntry.self, from: encoder.encode(entry))
    #expect(decoded == entry)
  }

  @Test func hookBusyWithoutPIDRoundTrips() throws {
    let entry = TranscriptEntry.hookBusy(active: false, pid: nil, surfaceID: surfaceID, at: fixedDate)
    let decoded = try decoder.decode(TranscriptEntry.self, from: encoder.encode(entry))
    #expect(decoded == entry)
  }

  @Test func hookEventRoundTrips() throws {
    let entry = TranscriptEntry.hookEvent(
      agent: "claude",
      event: "Notification",
      title: "Claude Code",
      body: "Claude needs your permission to use Bash",
      sessionID: "sess-abc",
      awaitingClassifierVerdict: true,
      surfaceID: surfaceID,
      at: fixedDate
    )
    let decoded = try decoder.decode(TranscriptEntry.self, from: encoder.encode(entry))
    #expect(decoded == entry)
  }

  @Test func awaitingInputChangedRoundTrips() throws {
    let entry = TranscriptEntry.awaitingInputChanged(
      active: true, source: "screen-fallback", surfaceID: surfaceID, at: fixedDate
    )
    let decoded = try decoder.decode(TranscriptEntry.self, from: encoder.encode(entry))
    #expect(decoded == entry)
  }

  @Test func sessionLifecycleRoundTrips() throws {
    let entry = TranscriptEntry.sessionLifecycle(
      kind: "created", context: "agent=claude", at: fixedDate
    )
    let decoded = try decoder.decode(TranscriptEntry.self, from: encoder.encode(entry))
    #expect(decoded == entry)
  }

  @Test func autoObserverRegexLayerRoundTrips() throws {
    let entry = TranscriptEntry.autoObserver(
      fingerprintHash: "abc123",
      userInstructions: nil,
      layer: "regex",
      decision: "1",
      inferenceDurationMs: nil,
      at: fixedDate
    )
    let decoded = try decoder.decode(TranscriptEntry.self, from: encoder.encode(entry))
    #expect(decoded == entry)
  }

  @Test func autoObserverInferenceLayerRoundTrips() throws {
    let entry = TranscriptEntry.autoObserver(
      fingerprintHash: "def456",
      userInstructions: "prefer yes",
      layer: "inference",
      decision: nil,
      inferenceDurationMs: 1234,
      at: fixedDate
    )
    let decoded = try decoder.decode(TranscriptEntry.self, from: encoder.encode(entry))
    #expect(decoded == entry)
  }

  @Test func backgroundInferenceRoundTrips() throws {
    let entry = TranscriptEntry.backgroundInference(
      purpose: "auto-observer",
      mode: "claudeCLI",
      promptPreview: "Should I answer yes?",
      resultPreview: "y",
      error: nil,
      durationMs: 850,
      at: fixedDate
    )
    let decoded = try decoder.decode(TranscriptEntry.self, from: encoder.encode(entry))
    #expect(decoded == entry)
  }

  @Test func backgroundInferenceWithErrorRoundTrips() throws {
    let entry = TranscriptEntry.backgroundInference(
      purpose: "session-title",
      mode: "anthropicAPI",
      promptPreview: "…",
      resultPreview: nil,
      error: "missing API key",
      durationMs: 12,
      at: fixedDate
    )
    let decoded = try decoder.decode(TranscriptEntry.self, from: encoder.encode(entry))
    #expect(decoded == entry)
  }

  // MARK: - Forward-compat: missing fields use defaults

  @Test func hookEventWithOnlyDiscriminantAndAgentDecodes() throws {
    // Older writer may have omitted optional fields. We should still
    // produce a valid entry with empty / default payloads rather than
    // throwing.
    let json = #"{"kind":"hookEvent","agent":"claude"}"#.data(using: .utf8)!
    let decoded = try decoder.decode(TranscriptEntry.self, from: json)
    guard case let .hookEvent(agent, event, title, body, sessionID, awaiting, _, _) = decoded else {
      Issue.record("Expected .hookEvent, got \(decoded)")
      return
    }
    #expect(agent == "claude")
    #expect(event == "")
    #expect(title == nil)
    #expect(body == nil)
    #expect(sessionID == nil)
    #expect(awaiting == false)
  }

  @Test func sessionLifecycleWithMissingContextDecodes() throws {
    let json = #"{"kind":"sessionLifecycle","lifecycleKind":"parked"}"#.data(using: .utf8)!
    let decoded = try decoder.decode(TranscriptEntry.self, from: json)
    guard case let .sessionLifecycle(kind, context, _) = decoded else {
      Issue.record("Expected .sessionLifecycle, got \(decoded)")
      return
    }
    #expect(kind == "parked")
    #expect(context == nil)
  }

  // MARK: - Reader tolerance: unknown `kind` must not break the whole file

  @Test func readerSkipsUnknownKindsWithoutFailingTheFile() throws {
    // Write a small JSONL blob with one known entry, one unknown-kind
    // entry (future schema version), another known entry. Reader should
    // return the two known entries and skip the middle.
    let good1 = TranscriptEntry.input(text: "hello", at: fixedDate)
    let good2 = TranscriptEntry.sessionLifecycle(kind: "created", context: nil, at: fixedDate)

    var data = Data()
    data.append(try encoder.encode(good1))
    data.append(0x0A)
    data.append(#"{"kind":"someUnknownFutureKind","x":42}"#.data(using: .utf8)!)
    data.append(0x0A)
    data.append(try encoder.encode(good2))
    data.append(0x0A)

    let fm = FileManager.default
    let tmpDir = fm.temporaryDirectory
      .appending(path: "TranscriptEventsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmpDir) }
    let tmpFile = tmpDir.appending(path: "trace.jsonl", directoryHint: .notDirectory)
    try data.write(to: tmpFile)

    // Replicate the reader's per-line decode loop — we can't call
    // `TranscriptReader.loadEntries(tabID:)` directly because it resolves
    // a real Application Support path from a TerminalTabID.
    let text = String(data: data, encoding: .utf8)!
    var entries: [TranscriptEntry] = []
    for line in text.split(whereSeparator: \.isNewline) {
      guard let lineData = line.data(using: .utf8) else { continue }
      if let entry = try? decoder.decode(TranscriptEntry.self, from: lineData) {
        entries.append(entry)
      }
    }

    #expect(entries == [good1, good2])
  }

  // MARK: - Existing kinds still round-trip (regression guard)

  @Test func existingInputStillRoundTrips() throws {
    let entry = TranscriptEntry.input(text: "ls -la\n", at: fixedDate)
    let decoded = try decoder.decode(TranscriptEntry.self, from: encoder.encode(entry))
    #expect(decoded == entry)
  }

  @Test func existingOutputTurnStillRoundTrips() throws {
    let entry = TranscriptEntry.outputTurn(
      fullText: "full", delta: "delta", at: fixedDate
    )
    let decoded = try decoder.decode(TranscriptEntry.self, from: encoder.encode(entry))
    #expect(decoded == entry)
  }
}
