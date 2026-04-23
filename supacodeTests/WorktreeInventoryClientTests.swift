import Foundation
import Testing

@testable import Supacool

/// Parser-level tests for the `WorktreeInventoryClient`. Each parser is
/// pure string-in / struct-out, so we can exercise the full matrix
/// (happy path, malformed, edge cases) without any shell involvement.
/// The `live(shell:)` factory is covered separately via a scripted
/// `ShellClient` in the classify-driven tests below.
struct WorktreeInventoryClientParserTests {
  // MARK: - parseWorktreePorcelain

  @Test func parsesSingleWorktreeRecord() {
    let raw = """
      worktree /Users/jz/repo
      HEAD abc1234567890
      branch refs/heads/main

      """
    let entries = parseWorktreePorcelain(raw)
    #expect(entries.count == 1)
    #expect(entries[0].path == "/Users/jz/repo")
    #expect(entries[0].head == "abc1234567890")
    #expect(entries[0].branch == "main")
    #expect(entries[0].isBare == false)
  }

  @Test func parsesMultipleRecordsSeparatedByBlankLines() {
    let raw = """
      worktree /repos/main
      HEAD a1
      branch refs/heads/main

      worktree /repos/feature
      HEAD b2
      branch refs/heads/feature/foo

      worktree /repos/detached
      HEAD c3
      detached

      """
    let entries = parseWorktreePorcelain(raw)
    #expect(entries.count == 3)
    #expect(entries[0].branch == "main")
    #expect(entries[1].branch == "feature/foo")
    #expect(entries[2].branch == "")  // detached → empty branch
  }

  @Test func parsesBareWorktree() {
    let raw = """
      worktree /repos/main.git
      bare

      worktree /repos/feature
      HEAD b2
      branch refs/heads/feature

      """
    let entries = parseWorktreePorcelain(raw)
    #expect(entries.count == 2)
    #expect(entries[0].isBare)
    #expect(entries[1].isBare == false)
  }

  @Test func handlesMissingTrailingBlankLine() {
    // git sometimes omits the trailing separator when the last record
    // is the only record; the parser should still flush.
    let raw = """
      worktree /only
      HEAD x1
      branch refs/heads/only
      """
    let entries = parseWorktreePorcelain(raw)
    #expect(entries.count == 1)
    #expect(entries[0].path == "/only")
  }

  @Test func returnsEmptyForEmptyInput() {
    #expect(parseWorktreePorcelain("") == [])
    #expect(parseWorktreePorcelain("\n\n").isEmpty)
  }

  // MARK: - parseDuBytes

  @Test func parsesDuOutput() {
    // macOS: 1K blocks + tab + path.
    #expect(parseDuBytes("1500\t/tmp/repo\n") == 1_536_000)
    #expect(parseDuBytes("0\t/empty\n") == 0)
  }

  @Test func parseDuBytesReturnsNilForGarbage() {
    #expect(parseDuBytes("") == nil)
    #expect(parseDuBytes("nope") == nil)
  }

  // MARK: - parseLastCommit

  @Test func parsesLastCommitLine() throws {
    let raw = "abc1234567890123456789012345678901234567\u{1F}2026-04-23T14:30:00Z\u{1F}fix: typo\n"
    let commit = try #require(parseLastCommit(raw))
    #expect(commit.shortHash == "abc1234")
    #expect(commit.subject == "fix: typo")
    // Spot-check the date parsed to roughly the right instant.
    let components = Calendar(identifier: .gregorian).dateComponents(
      in: TimeZone(identifier: "UTC")!, from: commit.date)
    #expect(components.year == 2026)
    #expect(components.month == 4)
    #expect(components.day == 23)
  }

  @Test func parsesLastCommitWithSubjectContainingSeparators() throws {
    // Only the first two \x1f are separators; anything after the
    // second belongs to the subject.
    let raw = "f00\u{1F}2026-01-01T00:00:00Z\u{1F}merge: tab\there|pipe"
    let commit = try #require(parseLastCommit(raw))
    #expect(commit.subject == "merge: tab\there|pipe")
  }

  @Test func parseLastCommitReturnsNilForEmpty() {
    #expect(parseLastCommit("") == nil)
    #expect(parseLastCommit("\n") == nil)
    #expect(parseLastCommit("abc") == nil)  // missing separators
  }

  // MARK: - parsePorcelainLineCount

  @Test func countsDirtyLines() {
    let raw = """
       M src/main.swift
      ?? Untracked.swift
      A  staged.swift

      """
    #expect(parsePorcelainLineCount(raw) == 3)
  }

  @Test func porcelainCountIsZeroForClean() {
    #expect(parsePorcelainLineCount("") == 0)
    #expect(parsePorcelainLineCount("\n\n") == 0)
  }

  // MARK: - parseAheadBehind

  @Test func parsesAheadBehindCounts() throws {
    // Format: "<behind>\t<ahead>" — left-right with --left-right
    // --count base...HEAD.
    let result = try #require(parseAheadBehind("3\t7\n"))
    #expect(result.behind == 3)
    #expect(result.ahead == 7)
  }

  @Test func parseAheadBehindReturnsNilForMalformed() {
    #expect(parseAheadBehind("") == nil)
    #expect(parseAheadBehind("3") == nil)
    #expect(parseAheadBehind("a\tb") == nil)
  }
}

// MARK: - Classification

struct WorktreeInventoryClassifyTests {
  @Test func flagsRepoRootAsNonCandidate() {
    let entries = [
      GitWtWorktreeEntry(branch: "main", path: "/repos/foo", head: "a", isBare: false)
    ]
    let result = classifyWorktreeInventory(
      entries: entries,
      sessions: [],
      repositoryID: "/repos/foo"
    )
    #expect(result.count == 1)
    #expect(result[0].status == .repoRoot)
    #expect(result[0].isDeletionCandidate == false)
  }

  @Test func flagsOrphanWithNoMatchingSession() {
    let entries = [
      GitWtWorktreeEntry(branch: "feature", path: "/repos/foo/wt1", head: "a", isBare: false)
    ]
    let result = classifyWorktreeInventory(
      entries: entries,
      sessions: [],
      repositoryID: "/repos/foo"
    )
    #expect(result[0].status == .orphan)
    #expect(result[0].isDeletionCandidate)
  }

  @Test func flagsOwnedWhenSessionWorktreeIDMatches() {
    let session = AgentSession(
      repositoryID: "/repos/foo",
      worktreeID: "/repos/foo/wt1",
      agent: .claude,
      initialPrompt: "test",
      displayName: "Fix login"
    )
    let entries = [
      GitWtWorktreeEntry(branch: "feature", path: "/repos/foo/wt1", head: "a", isBare: false)
    ]
    let result = classifyWorktreeInventory(
      entries: entries,
      sessions: [session],
      repositoryID: "/repos/foo"
    )
    guard case .owned(let id, let name) = result[0].status else {
      Issue.record("Expected owned, got \(result[0].status)")
      return
    }
    #expect(id == session.id)
    #expect(name == "Fix login")
  }

  @Test func flagsOwnedWhenCurrentWorkspacePathMatches() {
    // Mirrors the convert-to-worktree popover flow: worktreeID stays
    // anchored at the repo root while currentWorkspacePath diverges to
    // the freshly-created worktree dir. Both paths must resolve owners.
    let session = AgentSession(
      repositoryID: "/repos/foo",
      worktreeID: "/repos/foo",
      currentWorkspacePath: "/repos/foo/converted",
      agent: .claude,
      initialPrompt: "convert"
    )
    let entries = [
      GitWtWorktreeEntry(branch: "converted", path: "/repos/foo/converted", head: "a", isBare: false)
    ]
    let result = classifyWorktreeInventory(
      entries: entries,
      sessions: [session],
      repositoryID: "/repos/foo"
    )
    guard case .owned = result[0].status else {
      Issue.record("Expected owned via currentWorkspacePath, got \(result[0].status)")
      return
    }
  }

  @Test func ignoresSessionsFromOtherRepos() {
    let foreignSession = AgentSession(
      repositoryID: "/repos/other",
      worktreeID: "/repos/foo/wt1",  // same path, wrong repo
      agent: .claude,
      initialPrompt: "x"
    )
    let entries = [
      GitWtWorktreeEntry(branch: "feature", path: "/repos/foo/wt1", head: "a", isBare: false)
    ]
    let result = classifyWorktreeInventory(
      entries: entries,
      sessions: [foreignSession],
      repositoryID: "/repos/foo"
    )
    #expect(result[0].status == .orphan)
  }

  @Test func filtersBareWorktreesFromInventory() {
    let entries = [
      GitWtWorktreeEntry(branch: "(bare)", path: "/repos/foo.git", head: "", isBare: true),
      GitWtWorktreeEntry(branch: "main", path: "/repos/foo", head: "a", isBare: false),
    ]
    let result = classifyWorktreeInventory(
      entries: entries,
      sessions: [],
      repositoryID: "/repos/foo"
    )
    #expect(result.count == 1)
    #expect(result[0].name == "foo")
  }

  @Test func normalizesTrailingSlashMismatches() {
    // Repo registered with trailing slash, worktree path without.
    // standardizedFileURL should collapse both to the same canonical
    // form and let us detect the repo root.
    let entries = [
      GitWtWorktreeEntry(branch: "main", path: "/repos/foo", head: "a", isBare: false)
    ]
    let result = classifyWorktreeInventory(
      entries: entries,
      sessions: [],
      repositoryID: "/repos/foo/"
    )
    #expect(result[0].status == .repoRoot)
  }

  @Test func preservesBranchAndHeadOnClassification() {
    let entries = [
      GitWtWorktreeEntry(branch: "feature/x", path: "/repos/foo/wt", head: "abc123", isBare: false)
    ]
    let result = classifyWorktreeInventory(
      entries: entries,
      sessions: [],
      repositoryID: "/repos/foo"
    )
    #expect(result[0].branch == "feature/x")
    #expect(result[0].head == "abc123")
  }

  // MARK: - applyUncommittedCount

  @Test func upgradeOrphanToOrphanDirtyWhenCountPositive() {
    let orphan = WorktreeInventoryEntry(
      id: "/wt", name: "wt", branch: "x", head: "a", status: .orphan
    )
    let updated = applyUncommittedCount(3, to: orphan)
    #expect(updated.status == .orphanDirty)
    #expect(updated.uncommittedCount == 3)
  }

  @Test func keepsOrphanWhenCountZero() {
    let orphan = WorktreeInventoryEntry(
      id: "/wt", name: "wt", branch: "x", head: "a", status: .orphan
    )
    let updated = applyUncommittedCount(0, to: orphan)
    #expect(updated.status == .orphan)
    #expect(updated.uncommittedCount == 0)
  }

  @Test func doesNotDowngradeOwnedRowsEvenWhenDirty() {
    // An owned session's uncommitted work is its agent's work in
    // progress; we never want the janitor to flag it dirty in a way
    // that implies deletion.
    let owned = WorktreeInventoryEntry(
      id: "/wt", name: "wt", branch: "x", head: "a",
      status: .owned(sessionID: UUID(), displayName: "Session")
    )
    let updated = applyUncommittedCount(5, to: owned)
    if case .owned = updated.status {} else {
      Issue.record("Expected owned status to survive uncommitted-count merge")
    }
    #expect(updated.uncommittedCount == 5)
  }

  @Test func doesNotTouchRepoRootEvenWhenDirty() {
    let root = WorktreeInventoryEntry(
      id: "/repos/foo", name: "foo", branch: "main", head: "a", status: .repoRoot
    )
    let updated = applyUncommittedCount(10, to: root)
    #expect(updated.status == .repoRoot)
    #expect(updated.uncommittedCount == 10)
  }
}

// MARK: - Live client wiring

struct WorktreeInventoryClientLiveTests {
  @Test func listParsesPorcelainAndReturnsNonBareEntries() async throws {
    let shell = scriptedShell { args in
      // Expect: env git -C /repos/foo worktree list --porcelain
      #expect(args.contains("worktree"))
      #expect(args.contains("--porcelain"))
      return ShellOutput(
        stdout: """
          worktree /repos/foo
          HEAD a1
          branch refs/heads/main

          worktree /repos/foo/wt
          HEAD b2
          branch refs/heads/feature

          """,
        stderr: "",
        exitCode: 0
      )
    }
    let client = WorktreeInventoryClient.live(shell: shell)
    let entries = try await client.list(URL(fileURLWithPath: "/repos/foo"))
    #expect(entries.count == 2)
    #expect(entries.map(\.branch) == ["main", "feature"])
  }

  @Test func measureReturnsZeroWhenDuUnparseable() async throws {
    let shell = scriptedShell { _ in
      ShellOutput(stdout: "garbage\n", stderr: "", exitCode: 0)
    }
    let client = WorktreeInventoryClient.live(shell: shell)
    let bytes = try await client.measure(URL(fileURLWithPath: "/wt"))
    #expect(bytes == 0)
  }

  @Test func measureConvertsBlocksToBytes() async throws {
    let shell = scriptedShell { _ in
      ShellOutput(stdout: "2048\t/wt\n", stderr: "", exitCode: 0)
    }
    let client = WorktreeInventoryClient.live(shell: shell)
    let bytes = try await client.measure(URL(fileURLWithPath: "/wt"))
    #expect(bytes == 2_097_152)  // 2048 blocks × 1024 bytes
  }

  @Test func gitMetadataBundlesThreeCalls() async throws {
    let shell = scriptedShell { args in
      if args.contains("log"), args.contains("-1") {
        return ShellOutput(
          stdout: "abcd\u{1F}2026-04-23T12:00:00Z\u{1F}fix thing\n",
          stderr: "",
          exitCode: 0
        )
      }
      if args.contains("status"), args.contains("--porcelain") {
        return ShellOutput(stdout: " M a.swift\n M b.swift\n", stderr: "", exitCode: 0)
      }
      if args.contains("rev-list"), args.contains("--left-right") {
        return ShellOutput(stdout: "1\t4\n", stderr: "", exitCode: 0)
      }
      throw ScriptedShellError.unexpected(args: args)
    }
    let client = WorktreeInventoryClient.live(shell: shell)
    let metadata = try await client.gitMetadata(
      URL(fileURLWithPath: "/wt"),
      "origin/main"
    )
    #expect(metadata.lastCommit?.shortHash == "abcd")
    #expect(metadata.uncommittedCount == 2)
    #expect(metadata.aheadBehind == .init(ahead: 4, behind: 1))
  }

  @Test func gitMetadataToleratesPartialFailures() async throws {
    // If the log call errors but status+rev-list succeed, we still
    // want the non-erroring fields populated. Regression guard against
    // "one failure poisons the whole row."
    let shell = scriptedShell { args in
      if args.contains("log") {
        throw ScriptedShellError.unexpected(args: args)
      }
      if args.contains("status") {
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      }
      if args.contains("rev-list") {
        return ShellOutput(stdout: "0\t0\n", stderr: "", exitCode: 0)
      }
      throw ScriptedShellError.unexpected(args: args)
    }
    let client = WorktreeInventoryClient.live(shell: shell)
    let metadata = try await client.gitMetadata(
      URL(fileURLWithPath: "/wt"),
      "origin/main"
    )
    #expect(metadata.lastCommit == nil)
    #expect(metadata.uncommittedCount == 0)
    #expect(metadata.aheadBehind == .init(ahead: 0, behind: 0))
  }
}

// MARK: - Helpers

private enum ScriptedShellError: Error {
  case unexpected(args: [String])
}

/// Minimal `ShellClient` for unit tests: delegates both `run` and
/// `runLogin` to the provided handler. `runStream` paths aren't exercised.
private func scriptedShell(
  handler: @escaping @Sendable ([String]) async throws -> ShellOutput
) -> ShellClient {
  ShellClient(
    run: { _, arguments, _ in try await handler(arguments) },
    runLoginImpl: { _, arguments, _, _ in try await handler(arguments) }
  )
}
