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

  @Test func discoverSurfacesSlashCommandsAsUserInvocableSkills() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }

    let userSkillsRoot = root.appending(path: "user-skills", directoryHint: .isDirectory)
    let userCommandsRoot = root.appending(path: "user-commands", directoryHint: .isDirectory)
    let projectCommandsRoot = root.appending(path: "project-commands", directoryHint: .isDirectory)

    try writeSkill(
      named: "world-builder",
      description: "Use this skill when building worlds.",
      to: userSkillsRoot
    )
    // Command with frontmatter description.
    try writeCommand(
      relativePath: "c-ci-triage.md",
      contents: """
      ---
      description: Triage CI failures for the repo.
      ---

      Do the triage.
      """,
      to: projectCommandsRoot
    )
    // Command without frontmatter — description falls back to the first body line.
    try writeCommand(
      relativePath: "make-plan.md",
      contents: """
      # Make a plan

      Analyze the problem and produce a plan.
      """,
      to: userCommandsRoot
    )
    // Namespaced command in a subdirectory → `git:commit`.
    try writeCommand(
      relativePath: "git/commit.md",
      contents: "Stage and commit.",
      to: userCommandsRoot
    )

    let skills = await SkillCatalog.discover(
      userSkillsRoot: userSkillsRoot,
      projectSkillsRoot: nil,
      userCommandsRoot: userCommandsRoot,
      projectCommandsRoot: projectCommandsRoot
    )

    #expect(skills.map(\.name) == ["c-ci-triage", "git:commit", "make-plan", "world-builder"])

    let triage = try #require(skills.first(where: { $0.name == "c-ci-triage" }))
    #expect(triage.isUserInvocable)
    #expect(triage.source == .project)
    #expect(triage.description == "Triage CI failures for the repo.")

    let makePlan = try #require(skills.first(where: { $0.name == "make-plan" }))
    #expect(makePlan.description == "Make a plan")

    let commit = try #require(skills.first(where: { $0.name == "git:commit" }))
    #expect(commit.description == "Stage and commit.")
    #expect(commit.isUserInvocable)
  }

  @Test func discoverLetsSkillsKeepPrecedenceOverSameNamedCommands() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }

    let userSkillsRoot = root.appending(path: "user-skills", directoryHint: .isDirectory)
    let userCommandsRoot = root.appending(path: "user-commands", directoryHint: .isDirectory)

    try writeSkill(
      named: "overlap",
      description: "Use this skill when overlapping.",
      to: userSkillsRoot
    )
    try writeCommand(
      relativePath: "overlap.md",
      contents: "A command that shares the skill's name.",
      to: userCommandsRoot
    )

    let skills = await SkillCatalog.discover(
      userSkillsRoot: userSkillsRoot,
      projectSkillsRoot: nil,
      userCommandsRoot: userCommandsRoot,
      projectCommandsRoot: nil
    )

    let overlap = try #require(skills.first(where: { $0.name == "overlap" }))
    #expect(skills.filter { $0.name == "overlap" }.count == 1)
    #expect(overlap.description == "Use this skill when overlapping.")
  }

  @Test func discoverTreatsDisableModelInvocationSkillsAsUserInvocable() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }

    let userSkillsRoot = root.appending(path: "user-skills", directoryHint: .isDirectory)
    let skillDirectory = userSkillsRoot.appending(path: "c-ci-triage", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
    // No "use this skill when" / "triggers on" phrasing in the description, so
    // the description heuristic alone would mark it non-user-invocable. The
    // `disable-model-invocation: true` flag must override that.
    try """
    ---
    name: c-ci-triage
    description: Autonomous CI triage evaluator that spawns a doer subagent.
    disable-model-invocation: true
    ---

    # c-ci-triage
    """.write(
      to: skillDirectory.appending(path: "SKILL.md", directoryHint: .notDirectory),
      atomically: true,
      encoding: .utf8
    )

    let skills = await SkillCatalog.discover(userSkillsRoot: userSkillsRoot, projectSkillsRoot: nil)

    let triage = try #require(skills.first(where: { $0.name == "c-ci-triage" }))
    #expect(triage.isUserInvocable)
  }

  private func writeCommand(relativePath: String, contents: String, to root: URL) throws {
    let fileURL = root.appending(path: relativePath, directoryHint: .notDirectory)
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true,
      attributes: nil
    )
    try contents.write(to: fileURL, atomically: true, encoding: .utf8)
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
