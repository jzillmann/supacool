import Foundation
import Testing

@testable import Supacool

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

  @Test func discoverCodexKeepsDuplicateNamesAndLoadsHiddenSystemRoots() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }

    let projectSkillsRoot = root.appending(path: "project-skills", directoryHint: .isDirectory)
    let userAgentsSkillsRoot = root.appending(path: "user-agents", directoryHint: .isDirectory)
    let userCodexSkillsRoot = root.appending(path: "user-codex", directoryHint: .isDirectory)
    let adminSkillsRoot = root.appending(path: "admin-skills", directoryHint: .isDirectory)
    let builtinSkillsRoot = root.appending(path: "builtin-skills", directoryHint: .isDirectory)

    try writeSkill(
      named: "repo-helper",
      description: "Repo-scoped Codex helper.",
      to: projectSkillsRoot
    )
    try writeSkill(
      named: "shared-skill",
      description: "User skill from ~/.agents/skills.",
      to: userAgentsSkillsRoot
    )
    try writeSkill(
      named: "shared-skill",
      description: "Bundled skill from ~/.codex/skills/.system.",
      to: userCodexSkillsRoot.appending(path: ".system", directoryHint: .isDirectory)
    )
    try writeSkill(
      named: "admin-helper",
      description: "Admin helper from /etc/codex/skills.",
      to: adminSkillsRoot
    )
    try writeSkill(
      named: "builtin-helper",
      description: "Built-in skill from vendor imports.",
      to: builtinSkillsRoot.appending(path: ".curated", directoryHint: .isDirectory)
    )

    let skills = await SkillCatalog.discoverCodex(
      projectSkillsRoot: projectSkillsRoot,
      userAgentsSkillsRoot: userAgentsSkillsRoot,
      userCodexSkillsRoot: userCodexSkillsRoot,
      userCodexSystemSkillsRoot: userCodexSkillsRoot.appending(path: ".system", directoryHint: .isDirectory),
      adminSkillsRoot: adminSkillsRoot,
      builtinSkillsRoot: builtinSkillsRoot
    )

    #expect(skills.map(\.name) == ["admin-helper", "builtin-helper", "repo-helper", "shared-skill", "shared-skill"])
    #expect(skills.allSatisfy { $0.isUserInvocable })

    let sharedSkills = skills.filter { $0.name == "shared-skill" }
    #expect(sharedSkills.count == 2)
    #expect(Set(sharedSkills.map(\.id)).count == 2)
    #expect(sharedSkills.contains(where: { $0.source == .user }))
    #expect(sharedSkills.contains(where: { $0.source == .builtin }))

    let builtinHelper = try #require(skills.first(where: { $0.name == "builtin-helper" }))
    #expect(builtinHelper.source == .builtin)
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
