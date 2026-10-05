import Foundation
import Testing

@testable import Supacool

struct NativeSessionLocatorTests {
  private static let cwd = "/Users/me/.supacool/repos/trace/risk"
  private static let prompt = "Review these pull requests together, as one piece of work: https://example.com/pull/1"
  private static let launchedAt = Date(timeIntervalSince1970: 1_790_000_000)

  private static func metaLine(id: String, cwd: String = cwd, startedAt: Date = launchedAt) -> String {
    let timestamp = startedAt.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    return #"{"type":"session_meta","payload":{"id":"\#(id)","timestamp":"\#(timestamp)","cwd":"\#(cwd)"}}"#
  }

  private static func userLine(_ text: String) -> String {
    let content = [["type": "input_text", "text": text]]
    let object: [String: Any] = [
      "type": "response_item",
      "payload": ["type": "message", "role": "user", "content": content],
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return "" }
    return String(bytes: data, encoding: .utf8) ?? ""
  }

  private static var promptKey: String { NativeSessionLocatorLive.promptKey(prompt) }

  @Test func matchesRolloutLaunchedWithThePrompt() {
    let lines = [
      Self.metaLine(id: "codex-1"),
      Self.userLine("# AGENTS.md instructions for \(Self.cwd)"),
      Self.userLine(Self.prompt + "\nThis is round 1 of 5."),
    ]
    let match = NativeSessionLocatorLive.matchCodexRollout(
      lines: lines,
      workingDirectory: Self.cwd + "/",
      promptKey: Self.promptKey,
      notBefore: Self.launchedAt.addingTimeInterval(-60)
    )
    #expect(match?.id == "codex-1")
  }

  @Test func rejectsOtherDirectoryOtherPromptOrEarlierStart() {
    let notBefore = Self.launchedAt.addingTimeInterval(-60)
    let otherCwd = [Self.metaLine(id: "a", cwd: "/elsewhere"), Self.userLine(Self.prompt)]
    let otherPrompt = [Self.metaLine(id: "b"), Self.userLine("Ask codex for feedback on the plan")]
    let tooEarly = [
      Self.metaLine(id: "c", startedAt: Self.launchedAt.addingTimeInterval(-3600)),
      Self.userLine(Self.prompt),
    ]
    for lines in [otherCwd, otherPrompt, tooEarly] {
      #expect(
        NativeSessionLocatorLive.matchCodexRollout(
          lines: lines,
          workingDirectory: Self.cwd,
          promptKey: Self.promptKey,
          notBefore: notBefore
        ) == nil
      )
    }
  }

  @Test func locatePicksEarliestMatchingRolloutInDayFolders() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "native-session-locator-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
    let parts = calendar.dateComponents([.year, .month, .day], from: Self.launchedAt)
    let year = try #require(parts.year)
    let month = try #require(parts.month)
    let day = try #require(parts.day)
    let dayFolder =
      root
      .appending(path: "\(year)", directoryHint: .isDirectory)
      .appending(path: month < 10 ? "0\(month)" : "\(month)", directoryHint: .isDirectory)
      .appending(path: day < 10 ? "0\(day)" : "\(day)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dayFolder, withIntermediateDirectories: true)

    func write(_ name: String, _ lines: [String]) throws {
      try lines.joined(separator: "\n").appending("\n")
        .write(to: dayFolder.appending(path: name), atomically: true, encoding: .utf8)
    }
    // The launched reviewer, a later manual relaunch with the same pasted
    // prompt, and an unrelated Codex call in the same worktree.
    try write(
      "rollout-a-reviewer.jsonl",
      [Self.metaLine(id: "reviewer", startedAt: Self.launchedAt.addingTimeInterval(2)), Self.userLine(Self.prompt)]
    )
    try write(
      "rollout-b-relaunch.jsonl",
      [Self.metaLine(id: "relaunch", startedAt: Self.launchedAt.addingTimeInterval(3600)), Self.userLine(Self.prompt)]
    )
    try write(
      "rollout-c-other.jsonl",
      [Self.metaLine(id: "other", startedAt: Self.launchedAt.addingTimeInterval(1)), Self.userLine("Plan feedback")]
    )

    let match = NativeSessionLocatorLive.locateCodexRollout(
      NativeSessionLocatorClient.Query(
        agentID: "codex",
        workingDirectory: Self.cwd,
        initialPrompt: Self.prompt,
        createdAt: Self.launchedAt
      ),
      sessionsRoot: root,
      calendar: calendar
    )
    #expect(match?.id == "reviewer")
  }

  @Test func emptyPromptNeverMatches() {
    let match = NativeSessionLocatorLive.locateCodexRollout(
      NativeSessionLocatorClient.Query(
        agentID: "codex",
        workingDirectory: Self.cwd,
        initialPrompt: "  ",
        createdAt: Self.launchedAt
      ),
      sessionsRoot: URL(fileURLWithPath: "/nonexistent")
    )
    #expect(match == nil)
  }
}
