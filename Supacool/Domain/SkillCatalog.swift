import Foundation

struct Skill: Identifiable, Hashable, Sendable {
  let name: String
  let description: String
  let source: Source
  let definitionPath: String
  let isUserInvocable: Bool

  var id: String { definitionPath }

  nonisolated enum Source: String, Sendable {
    case user
    case project
    case admin
    case builtin
  }
}

enum SkillCatalog {
  static func discover(for agent: AgentType?, projectRoot: URL?) async -> [Skill] {
    switch agent {
    case .claude?:
      return await discoverClaude(projectRoot: projectRoot)
    case .codex?:
      return await discoverCodex(projectRoot: projectRoot)
    case .none:
      return []
    }
  }

  static func discoverClaude(projectRoot: URL?) async -> [Skill] {
    let userSkillsRoot = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".claude/skills", directoryHint: .isDirectory)
    let projectSkillsRoot = projectRoot?.appending(path: ".claude/skills", directoryHint: .isDirectory)

    return await discover(
      userSkillsRoot: userSkillsRoot,
      projectSkillsRoot: projectSkillsRoot
    )
  }

  static func discover(
    userSkillsRoot: URL?,
    projectSkillsRoot: URL?
  ) async -> [Skill] {
    async let userSkills = loadSkills(in: userSkillsRoot, source: .user, isUserInvocable: nil)
    async let projectSkills = loadSkills(in: projectSkillsRoot, source: .project, isUserInvocable: nil)

    var mergedByName: [String: Skill] = [:]
    for skill in await userSkills {
      mergedByName[skill.name] = skill
    }
    for skill in await projectSkills {
      mergedByName[skill.name] = skill
    }

    return mergedByName.values.sorted {
      $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
  }

  static func discoverCodex(projectRoot: URL?) async -> [Skill] {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let userAgentsRoot = home.appending(path: ".agents/skills", directoryHint: .isDirectory)
    let userCodexRoot = home.appending(path: ".codex/skills", directoryHint: .isDirectory)
    let userCodexSystemRoot = userCodexRoot.appending(path: ".system", directoryHint: .isDirectory)
    let builtinRoot = home.appending(path: ".codex/vendor_imports/skills/skills", directoryHint: .isDirectory)
    let adminRoot = URL(fileURLWithPath: "/etc/codex/skills", isDirectory: true)
    let projectSkillsRoot = projectRoot?.appending(path: ".agents/skills", directoryHint: .isDirectory)

    return await discoverCodex(
      projectSkillsRoot: projectSkillsRoot,
      userAgentsSkillsRoot: userAgentsRoot,
      userCodexSkillsRoot: userCodexRoot,
      userCodexSystemSkillsRoot: userCodexSystemRoot,
      adminSkillsRoot: adminRoot,
      builtinSkillsRoot: builtinRoot
    )
  }

  static func discoverCodex(
    projectSkillsRoot: URL?,
    userAgentsSkillsRoot: URL?,
    userCodexSkillsRoot: URL?,
    userCodexSystemSkillsRoot: URL?,
    adminSkillsRoot: URL?,
    builtinSkillsRoot: URL?
  ) async -> [Skill] {
    async let projectSkills = loadSkills(
      in: projectSkillsRoot,
      source: .project,
      isUserInvocable: true
    )
    async let userSkills = loadSkills(
      in: userAgentsSkillsRoot,
      source: .user,
      isUserInvocable: true
    )
    async let userCodexSkills = loadSkills(
      in: userCodexSkillsRoot,
      source: .user,
      isUserInvocable: true
    )
    async let adminSkills = loadSkills(
      in: adminSkillsRoot,
      source: .admin,
      isUserInvocable: true
    )
    async let builtinSkills = loadSkillsRecursively(
      in: builtinSkillsRoot,
      source: .builtin,
      isUserInvocable: true,
      skipsHiddenFiles: false
    )
    async let userCodexSystemSkills = loadSkillsRecursively(
      in: userCodexSystemSkillsRoot,
      source: .builtin,
      isUserInvocable: true,
      skipsHiddenFiles: false
    )

    return (await projectSkills
      + userSkills
      + userCodexSkills
      + adminSkills
      + userCodexSystemSkills
      + builtinSkills
    )
    .sorted { lhs, rhs in
      let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
      if nameOrder != .orderedSame {
        return nameOrder == .orderedAscending
      }
      let sourceOrder = sourceSortOrder(lhs.source) - sourceSortOrder(rhs.source)
      if sourceOrder != 0 {
        return sourceOrder < 0
      }
      return lhs.definitionPath.localizedCaseInsensitiveCompare(rhs.definitionPath) == .orderedAscending
    }
  }

  private static func loadSkills(
    in root: URL?,
    source: Skill.Source,
    isUserInvocable: Bool?
  ) -> [Skill] {
    let fileManager = FileManager.default
    guard let root else { return [] }
    guard let entries = try? fileManager.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    ) else {
      return []
    }

    return entries.compactMap { entry in
      guard isDirectory(entry, fileManager: fileManager) else { return nil }
      return loadSkill(
        at: entry.appending(path: "SKILL.md", directoryHint: .notDirectory),
        source: source,
        isUserInvocable: isUserInvocable
      )
    }
  }

  private static func loadSkillsRecursively(
    in root: URL?,
    source: Skill.Source,
    isUserInvocable: Bool?,
    skipsHiddenFiles: Bool = true
  ) -> [Skill] {
    let fileManager = FileManager.default
    guard let root else { return [] }
    guard let enumerator = fileManager.enumerator(
      at: root,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: skipsHiddenFiles ? [.skipsHiddenFiles] : []
    ) else {
      return []
    }

    return enumerator.compactMap { entry in
      guard let fileURL = entry as? URL else { return nil }
      guard fileURL.lastPathComponent == "SKILL.md" else { return nil }
      return loadSkill(at: fileURL, source: source, isUserInvocable: isUserInvocable)
    }
  }

  private static func loadSkill(
    at url: URL,
    source: Skill.Source,
    isUserInvocable: Bool?
  ) -> Skill? {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: url.path) else { return nil }
    guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    guard let frontmatter = parseFrontmatter(in: content) else { return nil }
    guard let name = frontmatter["name"]?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
      return nil
    }
    guard
      let description = frontmatter["description"]?.trimmingCharacters(in: .whitespacesAndNewlines),
      !description.isEmpty
    else {
      return nil
    }

    return Skill(
      name: name,
      description: description,
      source: source,
      definitionPath: url.path(percentEncoded: false),
      isUserInvocable: isUserInvocable ?? self.isUserInvocable(description: description)
    )
  }

  private static func parseFrontmatter(in content: String) -> [String: String]? {
    let lines = content.components(separatedBy: .newlines)
    guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else {
      return nil
    }

    var values: [String: String] = [:]
    var didCloseFence = false

    for line in lines.dropFirst() {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed == "---" {
        didCloseFence = true
        break
      }
      guard let colon = line.firstIndex(of: ":") else { continue }
      let key = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
      guard key == "name" || key == "description" else { continue }
      let valueStart = line.index(after: colon)
      let rawValue = line[valueStart...].trimmingCharacters(in: .whitespacesAndNewlines)
      values[key] = unquote(rawValue)
    }

    return didCloseFence ? values : nil
  }

  private static func unquote(_ value: String) -> String {
    guard value.count >= 2 else { return value }
    if value.hasPrefix("\""), value.hasSuffix("\"") {
      return String(value.dropFirst().dropLast())
    }
    if value.hasPrefix("'"), value.hasSuffix("'") {
      return String(value.dropFirst().dropLast())
    }
    return value
  }

  private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
    guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]) else { return false }
    return values.isDirectory == true
  }

  private static func isUserInvocable(description: String) -> Bool {
    let pattern = "(?i)(use this skill when|use when asked to|use when|this skill should be used when|use this skill|triggers on)"
    return description.range(of: pattern, options: .regularExpression) != nil
  }

  private static func sourceSortOrder(_ source: Skill.Source) -> Int {
    switch source {
    case .project: 0
    case .user: 1
    case .admin: 2
    case .builtin: 3
    }
  }
}
