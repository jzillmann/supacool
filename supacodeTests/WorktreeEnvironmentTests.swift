import Foundation
import Testing

@testable import supacode

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
    #expect(env["SUPACODE_WORKTREE_PATH"] == "/tmp/repo/wt-1")
    #expect(env["SUPACODE_ROOT_PATH"] == "/tmp/repo")
    #expect(env.count == 2)
  }

  @Test func exportPrefixFormatsCorrectly() {
    let worktree = Worktree(
      id: "/tmp/repo/wt-1",
      name: "feature-branch",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-1"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo/.bare"),
    )
    let exports = worktree.scriptEnvironmentExportPrefix
    #expect(exports.contains("export SUPACODE_WORKTREE_PATH='/tmp/repo/wt-1'"))
    #expect(exports.contains("export SUPACODE_ROOT_PATH='/tmp/repo/.bare'"))
    #expect(exports.hasSuffix("\n"))
  }

  @Test func exportPrefixIsSortedByKey() {
    let worktree = Worktree(
      id: "/tmp/repo/wt-1",
      name: "feature-branch",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-1"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo/.bare"),
    )
    let lines = worktree.scriptEnvironmentExportPrefix
      .trimmingCharacters(in: .newlines)
      .components(separatedBy: "\n")
    #expect(lines.count == 2)
    #expect(lines[0].contains("SUPACODE_ROOT_PATH"))
    #expect(lines[1].contains("SUPACODE_WORKTREE_PATH"))
  }

  @Test func exportPrefixQuotesPathsWithSpaces() {
    let worktree = Worktree(
      id: "/tmp/my repo/wt 1",
      name: "feature-branch",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: "/tmp/my repo/wt 1"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/my repo/.bare"),
    )
    let exports = worktree.scriptEnvironmentExportPrefix
    #expect(exports.contains("export SUPACODE_WORKTREE_PATH='/tmp/my repo/wt 1'"))
    #expect(exports.contains("export SUPACODE_ROOT_PATH='/tmp/my repo/.bare'"))
  }

  @Test func blockingScriptLaunchWritesScriptAndMetadataFiles() throws {
    let worktree = Worktree(
      id: "/tmp/repo/wt-1",
      name: "feature-branch",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-1"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo"),
    )

    let launch = try #require(
      try makeBlockingScriptLaunch(
        script: """
          docker compose down
          codex exec "test"
          """,
        environment: worktree.scriptEnvironment,
        shellPath: "/opt/homebrew/bin/fish"
      )
    )
    defer {
      try? FileManager.default.removeItem(at: launch.directoryURL)
    }

    let scriptContents = try String(contentsOf: launch.scriptURL, encoding: .utf8)
    let runnerContents = try String(contentsOf: launch.runnerURL, encoding: .utf8)
    let rootPathContents = try String(contentsOf: launch.rootPathURL, encoding: .utf8)
    let worktreePathContents = try String(contentsOf: launch.worktreePathURL, encoding: .utf8)
    let shellPathContents = try String(contentsOf: launch.shellPathURL, encoding: .utf8)

    #expect(
      launch.directoryURL.deletingLastPathComponent().path(percentEncoded: false)
        == FileManager.default.temporaryDirectory.path(percentEncoded: false)
    )
    #expect(launch.commandInput == shellSingleQuoted(launch.runnerURL.path(percentEncoded: false)) + "\n")
    #expect(scriptContents == "docker compose down\ncodex exec \"test\"\n")
    #expect(rootPathContents == "/tmp/repo\n")
    #expect(worktreePathContents == "/tmp/repo/wt-1\n")
    #expect(shellPathContents == "/opt/homebrew/bin/fish\n")
    #expect(
      runnerContents.contains(
        "IFS= read -r SUPACODE_ROOT_PATH < \(shellSingleQuoted(launch.rootPathURL.path(percentEncoded: false)))"
      )
        == true
    )
    #expect(
      runnerContents.contains(
        "IFS= read -r SUPACODE_WORKTREE_PATH < \(shellSingleQuoted(launch.worktreePathURL.path(percentEncoded: false)))"
      )
        == true
    )
    #expect(
      runnerContents.contains(
        "IFS= read -r SUPACODE_SHELL_PATH < \(shellSingleQuoted(launch.shellPathURL.path(percentEncoded: false)))"
      )
        == true
    )
    #expect(
      runnerContents.contains(
        "\"$SUPACODE_SHELL_PATH\" -l \(shellSingleQuoted(launch.scriptURL.path(percentEncoded: false)))"
      )
        == true
    )
    #expect(runnerContents.contains("exec") == false)
    #expect(runnerContents.contains("docker compose down") == false)
    #expect(runnerContents.contains("codex exec \"test\"") == false)
  }

  @Test func blockingScriptLaunchReturnsNilWhenRequiredEnvironmentIsMissing() throws {
    #expect(
      try makeBlockingScriptLaunch(
        script: "echo test",
        environment: ["SUPACODE_ROOT_PATH": "/tmp/repo"],
        shellPath: "/bin/zsh"
      ) == nil
    )
  }

  @Test func blockingScriptLaunchReturnsNilForWhitespaceOnlyScripts() throws {
    #expect(
      try makeBlockingScriptLaunch(
        script: """

          """,
        environment: [
          "SUPACODE_ROOT_PATH": "/tmp/repo",
          "SUPACODE_WORKTREE_PATH": "/tmp/repo/wt-1",
        ],
        shellPath: "/bin/zsh"
      ) == nil
    )
  }

  @Test func blockingScriptLaunchPropagatesNonZeroExitCodeInZsh() throws {
    let launch = try #require(
      try makeBlockingScriptLaunch(
        script: "exit 1",
        environment: [
          "SUPACODE_ROOT_PATH": "/tmp/repo",
          "SUPACODE_WORKTREE_PATH": "/tmp/repo/wt-1",
        ],
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
        environment: [
          "SUPACODE_ROOT_PATH": "/tmp/repo",
          "SUPACODE_WORKTREE_PATH": "/tmp/repo/wt-1",
        ],
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
}
