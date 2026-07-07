import Foundation
import Testing

@testable import Supacool

actor DiffForFileShellCallStore {
  private(set) var calls: [[String]] = []

  func record(_ arguments: [String]) {
    calls.append(arguments)
  }
}

struct GitClientDiffForFileTests {
  @Test func workingTreeDiffUsesHeadSoStagedOnlyChangesAreIncluded() async throws {
    let store = DiffForFileShellCallStore()
    let shell = ShellClient(
      run: { _, arguments, _ in
        await store.record(arguments)
        return ShellOutput(stdout: "diff --git a/file.txt b/file.txt\n", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell)

    let diff = try await client.diffForFile(
      at: URL(fileURLWithPath: "/tmp/repo"),
      path: "file.txt",
      cached: false
    )

    #expect(diff.hasPrefix("diff --git"))
    let calls = await store.calls
    #expect(calls.count == 1)
    #expect(calls[0] == ["git", "-C", "/tmp/repo", "diff", "HEAD", "--", "file.txt"])
  }

  @Test func cachedDiffUsesCachedFlagWithoutHead() async throws {
    let store = DiffForFileShellCallStore()
    let shell = ShellClient(
      run: { _, arguments, _ in
        await store.record(arguments)
        return ShellOutput(stdout: "diff --git a/file.txt b/file.txt\n", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell)

    _ = try await client.diffForFile(
      at: URL(fileURLWithPath: "/tmp/repo"),
      path: "file.txt",
      cached: true
    )

    let calls = await store.calls
    #expect(calls.count == 1)
    #expect(calls[0] == ["git", "-C", "/tmp/repo", "diff", "--cached", "--", "file.txt"])
  }
}
