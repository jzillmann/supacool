import Foundation
import Testing

@testable import Supacool

/// Exercises the decision logic inside `RepoSyncClient.live` by
/// injecting a scripted `ShellClient` that responds to git subcommand
/// invocations with pre-canned outputs. The tests don't shell out — no
/// `git` binary is required.
@MainActor
struct RepoSyncClientTests {
  @Test func skippedWhenOriginHeadUnresolvable() async {
    let shell = scriptedShell { args in
      if args.contains("symbolic-ref") {
        throw ShellClientError(
          command: "git symbolic-ref",
          stdout: "",
          stderr: "fatal: ref refs/remotes/origin/HEAD is not a symbolic ref",
          exitCode: 1
        )
      }
      throw UnexpectedCall(args: args)
    }
    let client = RepoSyncClient.live(shell: shell)
    let outcome = await client.syncIfSafe(URL(fileURLWithPath: "/tmp/repo"))
    #expect(outcome == .skippedNoDefaultBranch)
  }

  @Test func skippedWhenBranchIsNotDefault() async {
    let shell = scriptedShell { args in
      if args.contains("symbolic-ref") {
        return ShellOutput(stdout: "origin/main\n", stderr: "", exitCode: 0)
      }
      if args.contains("rev-parse"), args.contains("--abbrev-ref") {
        return ShellOutput(stdout: "feature/foo\n", stderr: "", exitCode: 0)
      }
      throw UnexpectedCall(args: args)
    }
    let client = RepoSyncClient.live(shell: shell)
    let outcome = await client.syncIfSafe(URL(fileURLWithPath: "/tmp/repo"))
    #expect(
      outcome
        == .skippedNotOnDefaultBranch(currentBranch: "feature/foo", defaultBranch: "main")
    )
  }

  @Test func skippedWhenTreeIsDirty() async {
    let shell = scriptedShell { args in
      if args.contains("symbolic-ref") {
        return ShellOutput(stdout: "origin/main\n", stderr: "", exitCode: 0)
      }
      if args.contains("rev-parse"), args.contains("--abbrev-ref") {
        return ShellOutput(stdout: "main\n", stderr: "", exitCode: 0)
      }
      if args.contains("status"), args.contains("--porcelain") {
        return ShellOutput(stdout: " M src/main.swift\n", stderr: "", exitCode: 0)
      }
      throw UnexpectedCall(args: args)
    }
    let client = RepoSyncClient.live(shell: shell)
    let outcome = await client.syncIfSafe(URL(fileURLWithPath: "/tmp/repo"))
    #expect(outcome == .skippedDirtyTree)
  }

  @Test func skippedWhenFetchFails() async {
    let shell = scriptedShell { args in
      if args.contains("symbolic-ref") {
        return ShellOutput(stdout: "origin/main\n", stderr: "", exitCode: 0)
      }
      if args.contains("rev-parse"), args.contains("--abbrev-ref") {
        return ShellOutput(stdout: "main\n", stderr: "", exitCode: 0)
      }
      if args.contains("status"), args.contains("--porcelain") {
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      }
      if args.contains("rev-parse"), args.contains("HEAD") {
        return ShellOutput(stdout: "abc123\n", stderr: "", exitCode: 0)
      }
      if args.contains("fetch") {
        throw ShellClientError(
          command: "git fetch",
          stdout: "",
          stderr: "fatal: unable to access",
          exitCode: 128
        )
      }
      throw UnexpectedCall(args: args)
    }
    let client = RepoSyncClient.live(shell: shell)
    let outcome = await client.syncIfSafe(URL(fileURLWithPath: "/tmp/repo"))
    if case .skippedFetchFailed = outcome {
      // ok
    } else {
      Issue.record("Expected .skippedFetchFailed, got \(outcome)")
    }
  }

  @Test func syncedAlreadyUpToDate() async {
    let shell = scriptedShell { args in
      if args.contains("symbolic-ref") {
        return ShellOutput(stdout: "origin/main\n", stderr: "", exitCode: 0)
      }
      if args.contains("rev-parse"), args.contains("--abbrev-ref") {
        return ShellOutput(stdout: "main\n", stderr: "", exitCode: 0)
      }
      if args.contains("status"), args.contains("--porcelain") {
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      }
      if args.contains("rev-parse"), args.contains("HEAD") {
        return ShellOutput(stdout: "abc123\n", stderr: "", exitCode: 0)
      }
      if args.contains("fetch") {
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      }
      if args.contains("merge"), args.contains("--ff-only") {
        return ShellOutput(stdout: "Already up to date.\n", stderr: "", exitCode: 0)
      }
      throw UnexpectedCall(args: args)
    }
    let client = RepoSyncClient.live(shell: shell)
    let outcome = await client.syncIfSafe(URL(fileURLWithPath: "/tmp/repo"))
    #expect(outcome == .synced(advancedBy: 0))
  }

  @Test func syncedAdvancedByThree() async {
    // rev-parse HEAD returns different shas before / after the merge;
    // rev-list --count reports 3.
    let shaCallCount = CallCounter()
    let shell = scriptedShell { args in
      if args.contains("symbolic-ref") {
        return ShellOutput(stdout: "origin/main\n", stderr: "", exitCode: 0)
      }
      if args.contains("rev-parse"), args.contains("--abbrev-ref") {
        return ShellOutput(stdout: "main\n", stderr: "", exitCode: 0)
      }
      if args.contains("status"), args.contains("--porcelain") {
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      }
      if args.contains("rev-parse"), args.contains("HEAD"),
        !args.contains("--abbrev-ref")
      {
        let count = await shaCallCount.increment()
        let sha = (count == 1) ? "aaa111\n" : "bbb222\n"
        return ShellOutput(stdout: sha, stderr: "", exitCode: 0)
      }
      if args.contains("fetch") {
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      }
      if args.contains("merge"), args.contains("--ff-only") {
        return ShellOutput(stdout: "Updating aaa..bbb\n", stderr: "", exitCode: 0)
      }
      if args.contains("rev-list"), args.contains("--count") {
        return ShellOutput(stdout: "3\n", stderr: "", exitCode: 0)
      }
      throw UnexpectedCall(args: args)
    }
    let client = RepoSyncClient.live(shell: shell)
    let outcome = await client.syncIfSafe(URL(fileURLWithPath: "/tmp/repo"))
    #expect(outcome == .synced(advancedBy: 3))
  }
}

// MARK: - Helpers

private struct UnexpectedCall: Error {
  let args: [String]
}

/// Builds a minimal `ShellClient` whose `run` invokes the provided
/// handler. Other entry points throw — the client only uses `run`, so
/// this is enough to exercise its behavior without dragging in process
/// spawning.
private func scriptedShell(
  handler: @escaping @Sendable ([String]) async throws -> ShellOutput
) -> ShellClient {
  ShellClient(
    run: { _, arguments, _ in
      try await handler(arguments)
    },
    runLoginImpl: { _, arguments, _, _ in
      try await handler(arguments)
    }
  )
}

/// Thread-safe call counter so the "advancedBy: 3" test can answer
/// "first call returned SHA A, second call returned SHA B" without
/// racing.
private actor CallCounter {
  private var count = 0
  func increment() -> Int {
    count += 1
    return count
  }
}
