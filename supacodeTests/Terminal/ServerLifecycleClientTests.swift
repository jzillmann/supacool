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
