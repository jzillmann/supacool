import Foundation
import Testing

@testable import Supacool

@MainActor
struct GitWorktreeHeadResolverTests {
  @Test func resolvesHeadFromNestedDirectoryInRegularRepository() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let gitDirectory = root.appending(path: ".git", directoryHint: .isDirectory)
    let nestedDirectory = root.appending(path: "Sources/App", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
    let expectedHead = gitDirectory.appending(path: "HEAD")
    try "ref: refs/heads/feature-x\n".write(to: expectedHead, atomically: true, encoding: .utf8)

    let resolved = GitWorktreeHeadResolver.headURL(for: nestedDirectory, fileManager: .default)

    #expect(resolved?.standardizedFileURL == expectedHead.standardizedFileURL)
  }

  @Test func resolvesHeadFromNestedDirectoryInLinkedWorktree() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let worktree = root.appending(path: "linked", directoryHint: .isDirectory)
    let nestedDirectory = worktree.appending(path: "Sources/App", directoryHint: .isDirectory)
    let gitDirectory = root.appending(path: ".git/worktrees/linked", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
    try "gitdir: ../.git/worktrees/linked\n".write(
      to: worktree.appending(path: ".git"),
      atomically: true,
      encoding: .utf8
    )
    let expectedHead = gitDirectory.appending(path: "HEAD")
    try "ref: refs/heads/worktree-branch\n".write(to: expectedHead, atomically: true, encoding: .utf8)

    let resolved = GitWorktreeHeadResolver.headURL(for: nestedDirectory, fileManager: .default)

    #expect(resolved?.standardizedFileURL == expectedHead.standardizedFileURL)
  }

  private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "GitWorktreeHeadResolverTests-")
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
