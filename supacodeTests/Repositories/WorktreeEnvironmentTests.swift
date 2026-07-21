import Foundation
import Testing

@testable import Supacool

@MainActor
struct WorktreeEnvironmentTests {
  @Test func scriptEnvironmentContainsExpectedKeys() {
    let worktree = Worktree(
      id: "/tmp/repo/wt-1",
      name: "feature-branch",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-1"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo"),
    )
    let env = worktree.scriptEnvironment
    #expect(env["SUPACOOL_WORKTREE_PATH"] == "/tmp/repo/wt-1")
    #expect(env["SUPACOOL_ROOT_PATH"] == "/tmp/repo")
    #expect(env["SUPACOOL_REPOSITORY_PATH"] == "/tmp/repo")
    #expect(env.count == 3)
  }

  @Test func blockingScriptLaunchWritesScriptAndMetadataFiles() throws {
    let launch = try #require(
      try makeBlockingScriptLaunch(
        script: """
          docker compose down
          codex exec "test"
          """,
        shellPath: "/opt/homebrew/bin/fish"
      )
    )
    defer {
      try? FileManager.default.removeItem(at: launch.directoryURL)
    }

    let scriptContents = try String(contentsOf: launch.scriptURL, encoding: .utf8)
    let runnerContents = try String(contentsOf: launch.runnerURL, encoding: .utf8)
    let shellPathContents = try String(contentsOf: launch.shellPathURL, encoding: .utf8)

    #expect(
      launch.directoryURL.deletingLastPathComponent().path(percentEncoded: false)
        == FileManager.default.temporaryDirectory.path(percentEncoded: false)
    )
    #expect(launch.commandInput == shellSingleQuoted(launch.runnerURL.path(percentEncoded: false)) + "\n")
    #expect(scriptContents == "docker compose down\ncodex exec \"test\"\n")
    #expect(shellPathContents == "/opt/homebrew/bin/fish\n")
    #expect(
      runnerContents.contains(
        "IFS= read -r SUPACOOL_SHELL_PATH < \(shellSingleQuoted(launch.shellPathURL.path(percentEncoded: false)))"
      )
        == true
    )
    #expect(
      runnerContents.contains(
        "\"$SUPACOOL_SHELL_PATH\" -l \(shellSingleQuoted(launch.scriptURL.path(percentEncoded: false)))"
      )
        == true
    )
    #expect(runnerContents.contains("exec") == false)
    #expect(runnerContents.contains("docker compose down") == false)
    #expect(runnerContents.contains("codex exec \"test\"") == false)
  }

  @Test func blockingScriptLaunchReturnsNilForWhitespaceOnlyScripts() throws {
    #expect(
      try makeBlockingScriptLaunch(
        script: """

          """,
        shellPath: "/bin/zsh"
      ) == nil
    )
  }

  @Test func blockingScriptLaunchPropagatesNonZeroExitCodeInZsh() throws {
    let launch = try #require(
      try makeBlockingScriptLaunch(
        script: "exit 1",
        shellPath: "/bin/zsh"
      )
    )
    let tempHome = URL(
      fileURLWithPath: "/tmp/supacode-zsh-home-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: launch.directoryURL)
      try? FileManager.default.removeItem(at: tempHome)
    }

    let process = Process()
    process.executableURL = launch.runnerURL
    process.environment = ["HOME": tempHome.path(percentEncoded: false)]

    try process.run()
    process.waitUntilExit()

    #expect(process.terminationStatus == 1)
  }

  @Test func blockingScriptCommandInputHandlesQuotedTempPathsInZsh() throws {
    let fileManager = FileManager.default
    let baseDirectoryURL = fileManager.temporaryDirectory.appending(
      path: "supacode temporary path's with spaces \(UUID().uuidString.lowercased())",
      directoryHint: .isDirectory
    )
    let launch = try #require(
      try makeBlockingScriptLaunch(
        script: "exit 1",
        shellPath: "/bin/zsh",
        baseDirectoryURL: baseDirectoryURL
      )
    )
    let tempHome = fileManager.temporaryDirectory.appending(
      path: "supacode-zsh-home-\(UUID().uuidString.lowercased())",
      directoryHint: .isDirectory
    )
    try fileManager.createDirectory(at: tempHome, withIntermediateDirectories: true)
    defer {
      try? fileManager.removeItem(at: launch.directoryURL)
      try? fileManager.removeItem(at: baseDirectoryURL)
      try? fileManager.removeItem(at: tempHome)
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-lc", launch.commandInput]
    process.environment = ["HOME": tempHome.path(percentEncoded: false)]

    try process.run()
    process.waitUntilExit()

    #expect(launch.commandInput.starts(with: "'") == true)
    #expect(process.terminationStatus == 1)
  }

  @Test func directPtyInputLimitStaysUnderMacOSCanonicalLineCap() {
    // MAX_CANON on macOS: a canonical-mode tty line is capped at 1024
    // bytes; the excess — including the newline — is silently dropped.
    #expect(maxDirectPtyInputBytes < 1024)
  }

  @Test func wrappedInputLaunchWritesExecutableRunnerAndShortInput() throws {
    let prompt = String(repeating: "long dictated prompt ", count: 70)
    let command = "bash -c 'go run ./cmd/dev worktree init'; claude --dangerously-skip-permissions '\(prompt)'\n"
    #expect(command.utf8.count > 1024)

    let launch = try #require(try makeWrappedInputLaunch(command: command))
    defer {
      try? FileManager.default.removeItem(at: launch.directoryURL)
    }

    let runnerContents = try String(contentsOf: launch.runnerURL, encoding: .utf8)
    #expect(runnerContents == "#!/bin/bash\n" + command.trimmingCharacters(in: .whitespacesAndNewlines) + "\n")
    #expect(FileManager.default.isExecutableFile(atPath: launch.runnerURL.path(percentEncoded: false)))
    #expect(launch.commandInput == shellSingleQuoted(launch.runnerURL.path(percentEncoded: false)) + "\n")
    #expect(launch.commandInput.utf8.count < maxDirectPtyInputBytes)
  }

  @Test func wrappedInputLaunchReturnsNilForWhitespaceOnlyCommands() throws {
    #expect(try makeWrappedInputLaunch(command: " \n ") == nil)
  }

  @Test func wrappedInputLaunchRunnerPreservesOversizedArgumentsInZsh() throws {
    let fileManager = FileManager.default
    let outputURL = fileManager.temporaryDirectory.appending(
      path: "supacool-wrapped-input-\(UUID().uuidString.lowercased()).out",
      directoryHint: .notDirectory
    )
    let payload = String(repeating: "x", count: 1500)
    let launch = try #require(
      try makeWrappedInputLaunch(
        command: "printf '%s' '\(payload)' > \(shellSingleQuoted(outputURL.path(percentEncoded: false)))\n"
      )
    )
    defer {
      try? fileManager.removeItem(at: launch.directoryURL)
      try? fileManager.removeItem(at: outputURL)
    }

    // Drive it the way the terminal does: the interactive shell receives
    // the short quoted runner path as typed input.
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-c", launch.commandInput]

    try process.run()
    process.waitUntilExit()

    #expect(process.terminationStatus == 0)
    let written = try String(contentsOf: outputURL, encoding: .utf8)
    #expect(written == payload)
  }
}
