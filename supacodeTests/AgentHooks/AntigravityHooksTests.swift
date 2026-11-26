import Foundation
import Testing

@testable import Supacool

struct AntigravityHooksTests {
  private let fileManager = FileManager.default

  @Test func installWritesPluginWithBusyAndStopHooks() throws {
    let home = URL(filePath: NSTemporaryDirectory()).appending(path: "agy-hooks-\(UUID().uuidString)")
    defer { try? fileManager.removeItem(at: home) }
    let installer = AntigravityHooksInstaller(homeDirectoryURL: home, fileManager: fileManager)

    try installer.install()

    let dir = home.appending(path: ".gemini/config/plugins/supacool")
    #expect(fileManager.fileExists(atPath: dir.appending(path: "plugin.json").path))
    let hooks = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appending(path: "hooks.json")))
    let events = try #require((hooks as? [String: [String: [[String: Any]]]])?["supacool"])
    #expect(events["PreInvocation"]?.first?["command"] as? String
      == AgentHookSettingsCommand.busyCommand(active: true))
    #expect(events["Stop"]?.compactMap { $0["command"] as? String } == [
      AgentHookSettingsCommand.busyCommand(active: false),
      AgentHookSettingsCommand.notificationCommand(agent: "antigravity"),
    ])
  }

  @Test func stopPayloadMapsConversationIDAndReadsFinalMessageFromTranscript() throws {
    let dir = URL(filePath: NSTemporaryDirectory()).appending(path: "agy-\(UUID().uuidString)/.gemini/logs")
    try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: dir.deletingLastPathComponent().deletingLastPathComponent()) }
    let transcript = dir.appending(path: "transcript_full.jsonl")
    try """
      {"source":"USER_EXPLICIT","type":"USER_INPUT","content":"open the PR"}
      {"source":"MODEL","type":"PLANNER_RESPONSE","content":"PR: https://github.com/a/b/pull/7"}
      {"source":"MODEL","type":"PLANNER_RESPONSE","tool_calls":[]}
      """.write(to: transcript, atomically: true, encoding: .utf8)
    let payload = #"{"hookEventName":"Stop","conversationId":"c-1","transcriptPath":"\#(transcript.path)"}"#
    let raw = "wt \(UUID().uuidString) \(UUID().uuidString) antigravity\n\(payload)"

    guard case .notification(_, _, _, let notification) = AgentHookSocketServer.parse(data: Data(raw.utf8)) else {
      Issue.record("Expected notification")
      return
    }
    #expect(notification.event == "Stop")
    #expect(notification.sessionID == "c-1")
    #expect(notification.body == "PR: https://github.com/a/b/pull/7")
  }

  @Test func transcriptOutsideGeminiIsNeverRead() {
    #expect(AgentHookSocketServer.lastAntigravityModelMessage(transcriptPath: "/etc/passwd") == nil)
  }
}
