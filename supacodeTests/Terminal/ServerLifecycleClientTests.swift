import Foundation
import Testing

@testable import Supacool

struct ServerLifecycleClientTests {
  private func makeWorktree(workingDirectory: URL) -> Worktree {
    Worktree(
      id: "wt-1",
      name: "test",
      detail: "",
      workingDirectory: workingDirectory,
      repositoryRootURL: workingDirectory,
      branch: "feature/test"
    )
  }

  private func makeTemporaryDirectory(_ label: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appending(path: "supacool-lifecycle-\(label)-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  // Regression test for the 2026-06-04 SIGABRT crash: `runServerLifecycleScript` read
  // `Process.terminationStatus` outside the termination handler, which raised an uncatchable
  // Objective-C exception and aborted the whole app. The exit code must now come back cleanly.
  @Test func runReturnsNonZeroExitCodeWithoutCrashing() async throws {
    let dir = try makeTemporaryDirectory("exit")
    defer { try? FileManager.default.removeItem(at: dir) }

    let result = try await ServerLifecycleClient.liveValue.run(
      makeWorktree(workingDirectory: dir),
      .stop,
      "printf 'stopping\\n'; printf 'oops\\n' 1>&2; exit 42",
      ServerLifecycleScriptContext(event: "test")
    )

    #expect(result.exitCode == 42)
    #expect(result.stdout.contains("stopping"))
    #expect(result.stderr.contains("oops"))
  }

  @Test func runReturnsZeroExitCodeOnSuccess() async throws {
    let dir = try makeTemporaryDirectory("ok")
    defer { try? FileManager.default.removeItem(at: dir) }

    let result = try await ServerLifecycleClient.liveValue.run(
      makeWorktree(workingDirectory: dir),
      .start,
      "printf '%s\\n' \"$SUPACOOL_LIFECYCLE_KIND\"",
      ServerLifecycleScriptContext(event: "launch")
    )

    #expect(result.exitCode == 0)
    #expect(result.stdout.contains("start"))
  }

  // Scripts run under a login shell, so a colourising tool (`dev status` bolds
  // its header) used to land its escape codes verbatim in the board chip's
  // tooltip as `[1mService Status[0m`.
  @Test func runStripsANSIEscapeCodesFromBothStreams() async throws {
    let dir = try makeTemporaryDirectory("ansi")
    defer { try? FileManager.default.removeItem(at: dir) }

    let result = try await ServerLifecycleClient.liveValue.run(
      makeWorktree(workingDirectory: dir),
      .status,
      "printf '\\033[1mService Status\\033[0m\\n'; printf '\\033[31mred\\033[0m\\n' 1>&2",
      ServerLifecycleScriptContext(event: "test")
    )

    #expect(result.stdout == "Service Status")
    #expect(result.stderr == "red")
    #expect(result.firstOutputLine == "Service Status")
  }

  @Test func combinedOutputJoinsBothStreamsAndSkipsEmptyOnes() {
    let both = ServerLifecycleScriptResult(exitCode: 0, stdout: "out", stderr: "err")
    #expect(both.combinedOutput == "out\nerr")

    let stdoutOnly = ServerLifecycleScriptResult(exitCode: 0, stdout: "out", stderr: "")
    #expect(stdoutOnly.combinedOutput == "out")

    let neither = ServerLifecycleScriptResult(exitCode: 0, stdout: "", stderr: "")
    #expect(neither.combinedOutput == "")
  }

  @Test func runShortCircuitsEmptyScript() async throws {
    let dir = try makeTemporaryDirectory("empty")
    defer { try? FileManager.default.removeItem(at: dir) }

    let result = try await ServerLifecycleClient.liveValue.run(
      makeWorktree(workingDirectory: dir),
      .status,
      "   \n  ",
      ServerLifecycleScriptContext(event: "noop")
    )

    #expect(result == ServerLifecycleScriptResult(exitCode: 0, stdout: "", stderr: ""))
  }
}
