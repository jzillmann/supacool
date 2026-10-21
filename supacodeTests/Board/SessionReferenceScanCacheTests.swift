import Foundation
import Testing

@testable import Supacool

/// Incremental transcript scans: only appended lines are read, and the result
/// matches a full scan of the same file.
struct SessionReferenceScanCacheTests {
  private static func userLine(_ text: String) -> String {
    #"{"type":"user","message":{"content":"\#(text)"}}"# + "\n"
  }

  private static func toolResultLine(_ text: String) -> String {
    #"{"type":"user","message":{"content":[{"type":"tool_result","content":"\#(text)"}]}}"# + "\n"
  }

  private func temporaryFile() -> URL {
    FileManager.default.temporaryDirectory
      .appending(path: "scan-cache-\(UUID().uuidString).jsonl", directoryHint: .notDirectory)
  }

  private func append(_ text: String, to url: URL) throws {
    if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
      try Data().write(to: url)
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(text.utf8))
  }

  @Test func appendedLinesAreScannedAndMatchAFullScan() async throws {
    let url = temporaryFile()
    defer { try? FileManager.default.removeItem(at: url) }
    let cache = SessionReferenceScanCache()

    try append(Self.userLine("fix CEN-1") + Self.toolResultLine("log CEN-9"), to: url)
    let first = await cache.scanClaudeJSONL(at: url, allowedPrefixes: [])
    #expect(first.references == [.ticket(id: "CEN-1")])

    // A second tool dump with CEN-9 clears the noise bar across the two scans.
    try append(Self.toolResultLine("again CEN-9") + Self.userLine("and CEN-2"), to: url)
    let second = await cache.scanClaudeJSONL(at: url, allowedPrefixes: [])
    let full = SessionReferenceScannerLive.scanJSONLDetailed(try String(contentsOf: url, encoding: .utf8))
    #expect(second == full)
    #expect(second.references == [.ticket(id: "CEN-1"), .ticket(id: "CEN-9"), .ticket(id: "CEN-2")])
  }

  @Test func aLineWithoutItsNewlineWaitsForTheNextScan() async throws {
    let url = temporaryFile()
    defer { try? FileManager.default.removeItem(at: url) }
    let cache = SessionReferenceScanCache()

    let line = Self.userLine("fix CEN-3")
    try append(String(line.dropLast(10)), to: url)
    #expect(await cache.scanClaudeJSONL(at: url, allowedPrefixes: []).references.isEmpty)
    try append(String(line.suffix(10)), to: url)
    #expect(await cache.scanClaudeJSONL(at: url, allowedPrefixes: []).references == [.ticket(id: "CEN-3")])
  }

  @Test func aReplacedFileIsScannedFromTheStart() async throws {
    let url = temporaryFile()
    defer { try? FileManager.default.removeItem(at: url) }
    let cache = SessionReferenceScanCache()

    try append(Self.userLine("fix CEN-4") + Self.userLine("more CEN-5"), to: url)
    _ = await cache.scanClaudeJSONL(at: url, allowedPrefixes: [])
    try FileManager.default.removeItem(at: url)
    try append(Self.userLine("now CEN-6"), to: url)
    #expect(await cache.scanClaudeJSONL(at: url, allowedPrefixes: []).references == [.ticket(id: "CEN-6")])
  }

  @Test func changedPrefixesRescanTheWholeFile() async throws {
    let url = temporaryFile()
    defer { try? FileManager.default.removeItem(at: url) }
    let cache = SessionReferenceScanCache()

    try append(Self.userLine("fix CEN-7 and TRA-8"), to: url)
    #expect(await cache.scanClaudeJSONL(at: url, allowedPrefixes: ["CEN"]).references == [.ticket(id: "CEN-7")])
    #expect(await cache.scanClaudeJSONL(at: url, allowedPrefixes: ["TRA"]).references == [.ticket(id: "TRA-8")])
  }

  @Test func linesSpanningChunksAreReadWhole() throws {
    let url = temporaryFile()
    defer { try? FileManager.default.removeItem(at: url) }
    try append("first line\nsecond line that is longer\nthird", to: url)

    var lines: [String] = []
    let offset = forEachLine(in: url, from: 0, chunkSize: 4) { lines.append(String(bytes: $0, encoding: .utf8) ?? "") }
    #expect(lines == ["first line", "second line that is longer"])
    #expect(offset == UInt64("first line\nsecond line that is longer\n".utf8.count))
  }
}
