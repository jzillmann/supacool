import Foundation
import Testing

@testable import Supacool

actor CommitHistoryShellCallStore {
  private(set) var calls: [[String]] = []

  func record(_ arguments: [String]) {
    calls.append(arguments)
  }
}

struct GitClientCommitHistoryTests {
  @Test func parseCommitHistoryHandlesMultipleRecords() throws {
    let raw = """
      abcdef1234567890\u{1F}abcdef1\u{1F}2026-05-14T10:15:30Z\u{1F}Jane Doe\u{1F}Add branch chip\u{1E}
      0123456789abcdef\u{1F}0123456\u{1F}2026-05-13T09:00:00Z\u{1F}John Doe\u{1F}Wire commit dialog\u{1E}
      """

    let commits = GitClient.parseCommitHistory(raw)

    #expect(commits.count == 2)
    #expect(commits[0].hash == "abcdef1234567890")
    #expect(commits[0].shortHash == "abcdef1")
    #expect(commits[0].author == "Jane Doe")
    #expect(commits[0].subject == "Add branch chip")
    #expect(commits[1].subject == "Wire commit dialog")
  }

  @Test func parseCommitHistoryDropsMalformedRecords() {
    let raw = "missing-fields\u{1E}abcdef1234567890\u{1F}\u{1F}2026-05-14T10:15:30Z\u{1F}Jane\u{1F}Subject\u{1E}"

    let commits = GitClient.parseCommitHistory(raw)

    #expect(commits.count == 1)
    #expect(commits[0].shortHash == "abcdef1")
  }

  @Test func commitHistoryRunsBoundedGitLog() async throws {
    let store = CommitHistoryShellCallStore()
    let output = "abcdef1234567890\u{1F}abcdef1\u{1F}2026-05-14T10:15:30Z\u{1F}Jane\u{1F}Subject\u{1E}"
    let shell = ShellClient(
      run: { _, arguments, _ in
        await store.record(arguments)
        return ShellOutput(stdout: output, stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell)

    let commits = try await client.commitHistory(at: URL(fileURLWithPath: "/tmp/repo"), limit: 500)

    #expect(commits.map(\.subject) == ["Subject"])
    let calls = await store.calls
    #expect(calls.count == 1)
    #expect(calls[0] == [
      "git",
      "-C",
      "/tmp/repo",
      "log",
      "--max-count=200",
      "--format=%H%x1f%h%x1f%cI%x1f%an%x1f%s%x1e",
    ])
  }
}
