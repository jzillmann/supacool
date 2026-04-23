import ConcurrencyExtras
import Foundation
import Testing

@testable import Supacool

struct AgentHookSettingsFileInstallerTests {
  private let fileManager = FileManager.default

  private func makeErrors() -> AgentHookSettingsFileInstaller.Errors {
    .init(
      invalidEventHooks: { TestInstallerError.invalidEventHooks($0) },
      invalidHooksObject: { TestInstallerError.invalidHooksObject },
      invalidJSON: { TestInstallerError.invalidJSON($0) },
      invalidRootObject: { TestInstallerError.invalidRootObject },
    )
  }

  private func makeInstaller() -> AgentHookSettingsFileInstaller {
    AgentHookSettingsFileInstaller(fileManager: fileManager, errors: makeErrors())
  }

  private func makeTempURL() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("supacode-test-\(UUID().uuidString)")
      .appendingPathComponent("settings.json")
  }

  private func sampleHookGroups() -> [String: [JSONValue]] {
    [
      "Stop": [
        .object([
          "hooks": .array([
            .object([
              "type": "command",
              "command": .string(AgentHookSettingsCommand.busyCommand(active: false)),
              "timeout": 10,
            ]),
          ]),
        ]),
      ],
    ]
  }

  // MARK: - Install.

  @Test func installIntoEmptyFileCreatesCorrectStructure() throws {
    let url = makeTempURL()
    defer { try? fileManager.removeItem(at: url.deletingLastPathComponent()) }

    let installer = makeInstaller()
    try installer.install(settingsURL: url, hookGroupsByEvent: sampleHookGroups())

    let data = try Data(contentsOf: url)
    let root = try JSONDecoder().decode(JSONValue.self, from: data)
    guard let hooksObject = root.objectValue?["hooks"]?.objectValue else {
      Issue.record("Expected hooks object")
      return
    }
    #expect(hooksObject["Stop"] != nil)
    let stopGroups = hooksObject["Stop"]?.arrayValue
    #expect(stopGroups?.count == 1)
  }

  @Test func installPreservesExistingNonHookKeys() throws {
    let url = makeTempURL()
    defer { try? fileManager.removeItem(at: url.deletingLastPathComponent()) }

    // Write a file with existing keys.
    let existing: JSONValue = .object(["customKey": "customValue"])
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true,
    )
    try JSONEncoder().encode(existing).write(to: url)

    let installer = makeInstaller()
    try installer.install(settingsURL: url, hookGroupsByEvent: sampleHookGroups())

    let data = try Data(contentsOf: url)
    let root = try JSONDecoder().decode(JSONValue.self, from: data)
    #expect(root.objectValue?["customKey"]?.stringValue == "customValue")
    #expect(root.objectValue?["hooks"] != nil)
  }

  @Test func installIsIdempotent() throws {
    let url = makeTempURL()
    defer { try? fileManager.removeItem(at: url.deletingLastPathComponent()) }

    let installer = makeInstaller()
    let groups = sampleHookGroups()
    try installer.install(settingsURL: url, hookGroupsByEvent: groups)
    try installer.install(settingsURL: url, hookGroupsByEvent: groups)

    let data = try Data(contentsOf: url)
    let root = try JSONDecoder().decode(JSONValue.self, from: data)
    let stopGroups = root.objectValue?["hooks"]?.objectValue?["Stop"]?.arrayValue
    // Should have exactly one group, not duplicates.
    #expect(stopGroups?.count == 1)
  }

  @Test func installPrunesLegacyCommands() throws {
    let url = makeTempURL()
    defer { try? fileManager.removeItem(at: url.deletingLastPathComponent()) }

    // Write a file with a legacy command.
    let legacy: JSONValue = .object([
      "hooks": .object([
        "Stop": .array([
          .object([
            "hooks": .array([
              .object([
                "type": "command",
                "command": "SUPACODE_CLI_PATH agent-hook --stop",
              ]),
            ]),
          ]),
        ]),
      ]),
    ])
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true,
    )
    try JSONEncoder().encode(legacy).write(to: url)

    let installer = makeInstaller()
    try installer.install(settingsURL: url, hookGroupsByEvent: sampleHookGroups())

    let data = try Data(contentsOf: url)
    let root = try JSONDecoder().decode(JSONValue.self, from: data)
    let stopGroups = root.objectValue?["hooks"]?.objectValue?["Stop"]?.arrayValue ?? []

    // Legacy command should be gone, only the new one remains.
    for group in stopGroups {
      guard let hooks = group.objectValue?["hooks"]?.arrayValue else { continue }
      for hook in hooks {
        let cmd = hook.objectValue?["command"]?.stringValue ?? ""
        #expect(!cmd.contains("SUPACODE_CLI_PATH"))
      }
    }
  }

  // MARK: - Uninstall.

  @Test func uninstallRemovesOnlyMatchingCommands() throws {
    let url = makeTempURL()
    defer { try? fileManager.removeItem(at: url.deletingLastPathComponent()) }

    let installer = makeInstaller()
    let groups = sampleHookGroups()
    try installer.install(settingsURL: url, hookGroupsByEvent: groups)

    // Also add a third-party hook manually.
    var data = try Data(contentsOf: url)
    var root = try JSONDecoder().decode(JSONValue.self, from: data).objectValue!
    var hooks = root["hooks"]!.objectValue!
    var stopGroups = hooks["Stop"]!.arrayValue!
    stopGroups.append(
      .object([
        "hooks": .array([
          .object([
            "type": "command",
            "command": "echo third-party",
          ]),
        ]),
      ]))
    hooks["Stop"] = .array(stopGroups)
    root["hooks"] = .object(hooks)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(JSONValue.object(root)).write(to: url)

    // Uninstall our hooks.
    try installer.uninstall(settingsURL: url, hookGroupsByEvent: groups)

    data = try Data(contentsOf: url)
    let updated = try JSONDecoder().decode(JSONValue.self, from: data)
    let remaining = updated.objectValue?["hooks"]?.objectValue?["Stop"]?.arrayValue ?? []

    // Third-party hook should remain.
    #expect(remaining.count == 1)
    let cmd = remaining[0].objectValue?["hooks"]?.arrayValue?[0].objectValue?["command"]?.stringValue
    #expect(cmd == "echo third-party")
  }

  @Test func uninstallOnMissingFileIsNoOp() throws {
    let url = makeTempURL()
    let installer = makeInstaller()
    // Should not throw — file doesn't exist.
    try installer.uninstall(settingsURL: url, hookGroupsByEvent: sampleHookGroups())
  }

  // MARK: - containsMatchingHooks.

  @Test func containsMatchingHooksReturnsTrueWhenPresent() throws {
    let url = makeTempURL()
    defer { try? fileManager.removeItem(at: url.deletingLastPathComponent()) }

    let installer = makeInstaller()
    let groups = sampleHookGroups()
    try installer.install(settingsURL: url, hookGroupsByEvent: groups)

    #expect(installer.containsMatchingHooks(settingsURL: url, hookGroupsByEvent: groups))
  }

  @Test func containsMatchingHooksReturnsFalseWhenMissing() {
    let url = makeTempURL()
    let installer = makeInstaller()
    #expect(!installer.containsMatchingHooks(settingsURL: url, hookGroupsByEvent: sampleHookGroups()))
  }

  @Test func containsMatchingHooksLogsInvalidJSONErrors() throws {
    let url = makeTempURL()
    let warnings = LockIsolated<[String]>([])
    defer { try? fileManager.removeItem(at: url.deletingLastPathComponent()) }

    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true,
    )
    try Data("not json".utf8).write(to: url)

    let installer = AgentHookSettingsFileInstaller(
      fileManager: fileManager,
      errors: makeErrors(),
      logWarning: { message in
        warnings.withValue { $0.append(message) }
      }
    )

    #expect(!installer.containsMatchingHooks(settingsURL: url, hookGroupsByEvent: sampleHookGroups()))
    #expect(warnings.value.count == 1)
    #expect(warnings.value[0].contains(url.path))
  }

  // MARK: - installState (tri-state).

  @Test func installStateMissingWhenNoFile() {
    let url = makeTempURL()
    let installer = makeInstaller()
    #expect(installer.installState(settingsURL: url, hookGroupsByEvent: sampleHookGroups()) == .missing)
  }

  @Test func installStateCurrentAfterInstall() throws {
    let url = makeTempURL()
    defer { try? fileManager.removeItem(at: url.deletingLastPathComponent()) }

    let installer = makeInstaller()
    let groups = sampleHookGroups()
    try installer.install(settingsURL: url, hookGroupsByEvent: groups)

    #expect(installer.installState(settingsURL: url, hookGroupsByEvent: groups) == .current)
  }

  @Test func installStateStaleWhenOneExpectedCommandMissing() throws {
    let url = makeTempURL()
    defer { try? fileManager.removeItem(at: url.deletingLastPathComponent()) }

    // Install the sample payload (busy-off on Stop only).
    let installer = makeInstaller()
    try installer.install(settingsURL: url, hookGroupsByEvent: sampleHookGroups())

    // Now ask about an *extended* payload that also expects a PreToolUse
    // busy-on hook. The file has one of the two expected commands → stale.
    let extendedGroups: [String: [JSONValue]] = sampleHookGroups().merging(
      [
        "PreToolUse": [
          .object([
            "hooks": .array([
              .object([
                "type": "command",
                "command": .string(AgentHookSettingsCommand.busyCommand(active: true)),
                "timeout": 5,
              ]),
            ]),
          ]),
        ],
      ],
      uniquingKeysWith: { lhs, _ in lhs }
    )

    #expect(
      installer.installState(settingsURL: url, hookGroupsByEvent: extendedGroups) == .stale
    )
  }

  @Test func installStateStaleWhenOnlyLegacyCommandPresent() throws {
    let url = makeTempURL()
    defer { try? fileManager.removeItem(at: url.deletingLastPathComponent()) }

    // Legacy pre-upgrade settings: a Supacode-owned legacy command lives in
    // the file, but none of the current expected commands. The installer
    // should report `.stale` (not `.missing`) so we can prompt a reinstall.
    let legacy: JSONValue = .object([
      "hooks": .object([
        "Stop": .array([
          .object([
            "hooks": .array([
              .object([
                "type": "command",
                "command": "SUPACODE_CLI_PATH agent-hook --stop",
              ]),
            ]),
          ]),
        ]),
      ]),
    ])
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true,
    )
    try JSONEncoder().encode(legacy).write(to: url)

    let installer = makeInstaller()
    #expect(installer.installState(settingsURL: url, hookGroupsByEvent: sampleHookGroups()) == .stale)
  }

  @Test func installStateMissingWhenFileHasUnrelatedHooks() throws {
    let url = makeTempURL()
    defer { try? fileManager.removeItem(at: url.deletingLastPathComponent()) }

    // Third-party (non-Supacode) hooks only — this is "you never installed
    // anything of ours", not "you have drift."
    let foreign: JSONValue = .object([
      "hooks": .object([
        "Stop": .array([
          .object([
            "hooks": .array([
              .object([
                "type": "command",
                "command": "echo third-party",
              ]),
            ]),
          ]),
        ]),
      ]),
    ])
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true,
    )
    try JSONEncoder().encode(foreign).write(to: url)

    let installer = makeInstaller()
    #expect(installer.installState(settingsURL: url, hookGroupsByEvent: sampleHookGroups()) == .missing)
  }

  @Test func containsMatchingHooksDoesNotLogMissingFile() {
    let url = makeTempURL()
    let warnings = LockIsolated<[String]>([])
    let installer = AgentHookSettingsFileInstaller(
      fileManager: fileManager,
      errors: makeErrors(),
      logWarning: { message in
        warnings.withValue { $0.append(message) }
      }
    )

    #expect(!installer.containsMatchingHooks(settingsURL: url, hookGroupsByEvent: sampleHookGroups()))
    #expect(warnings.value.isEmpty)
  }

  // MARK: - Error handling.

  @Test func invalidJSONFileThrowsWithDetail() throws {
    let url = makeTempURL()
    defer { try? fileManager.removeItem(at: url.deletingLastPathComponent()) }

    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true,
    )
    try Data("not json".utf8).write(to: url)

    let installer = makeInstaller()
    #expect(throws: TestInstallerError.self) {
      try installer.install(settingsURL: url, hookGroupsByEvent: sampleHookGroups())
    }
  }

  @Test func jsonArrayRootThrows() throws {
    let url = makeTempURL()
    defer { try? fileManager.removeItem(at: url.deletingLastPathComponent()) }

    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true,
    )
    try Data("[1,2,3]".utf8).write(to: url)

    let installer = makeInstaller()
    do {
      try installer.install(settingsURL: url, hookGroupsByEvent: sampleHookGroups())
      Issue.record("Expected invalidRootObject error")
    } catch let error as TestInstallerError {
      #expect(error == .invalidRootObject)
    }
  }
}

private enum TestInstallerError: Error, Equatable {
  case invalidEventHooks(String)
  case invalidHooksObject
  case invalidJSON(String)
  case invalidRootObject
}
