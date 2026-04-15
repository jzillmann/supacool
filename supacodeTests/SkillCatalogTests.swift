import Foundation
import Testing

@testable import supacode

struct SkillCatalogTests {
  @Test func discoverMergesProjectSkillsOverUserSkills() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }

    let userSkillsRoot = root.appending(path: "user", directoryHint: .isDirectory)
    let projectSkillsRoot = root.appending(path: "project", directoryHint: .isDirectory)

    try writeSkill(
      named: "world-builder",
      description: "Use this skill when building worlds.",
      to: userSkillsRoot
    )
    try writeSkill(
      named: "html-css-guidelines",
      description: "Principal front-end engineer standards for HTML and CSS.",
      to: userSkillsRoot
    )
    try writeSkill(
      named: "world-builder",
      description: "Project-local override for world generation.",
      to: projectSkillsRoot
    )

    let skills = await SkillCatalog.discover(
      userSkillsRoot: userSkillsRoot,
      projectSkillsRoot: projectSkillsRoot
    )

    #expect(skills.map(\.name) == ["html-css-guidelines", "world-builder"])

    let html = try #require(skills.first(where: { $0.name == "html-css-guidelines" }))
    #expect(html.source == .user)
    #expect(html.isUserInvocable == false)

    let worldBuilder = try #require(skills.first(where: { $0.name == "world-builder" }))
    #expect(worldBuilder.source == .project)
    #expect(worldBuilder.description == "Project-local override for world generation.")
    #expect(worldBuilder.isUserInvocable == false)
  }

  @Test func discoverSkipsMalformedSkillFiles() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }

    let userSkillsRoot = root.appending(path: "user", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: userSkillsRoot,
      withIntermediateDirectories: true,
      attributes: nil
    )

    let brokenSkillDirectory = userSkillsRoot.appending(path: "broken", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: brokenSkillDirectory,
      withIntermediateDirectories: true,
      attributes: nil
    )
    try """
    ---
    name: broken
    description: Missing closing fence
    """.write(
      to: brokenSkillDirectory.appending(path: "SKILL.md", directoryHint: .notDirectory),
      atomically: true,
      encoding: .utf8
    )

    let skills = await SkillCatalog.discover(
      userSkillsRoot: userSkillsRoot,
      projectSkillsRoot: nil
    )

    #expect(skills.isEmpty)
  }

  private func writeSkill(named name: String, description: String, to root: URL) throws {
    let directory = root.appending(path: name, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: nil
    )
    try """
    ---
    name: \(name)
    description: \(description)
    ---

    # \(name)
    """.write(
      to: directory.appending(path: "SKILL.md", directoryHint: .notDirectory),
      atomically: true,
      encoding: .utf8
    )
  }
}
