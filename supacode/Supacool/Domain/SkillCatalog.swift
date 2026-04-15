import Foundation

struct Skill: Identifiable, Hashable, Sendable {
  let name: String
  let description: String
  let source: Source
  let isUserInvocable: Bool

  var id: String { "\(source.rawValue)/\(name)" }

  nonisolated enum Source: String, Sendable {
    case user
    case project
  }
}

enum SkillCatalog {
  static func discover(projectRoot: URL?) async -> [Skill] {
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
    async let userSkills = loadSkills(in: userSkillsRoot, source: .user)
    async let projectSkills = loadSkills(in: projectSkillsRoot, source: .project)

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

  private static func loadSkills(
    in root: URL?,
    source: Skill.Source
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
        source: source
      )
    }
  }

  private static func loadSkill(
    at url: URL,
    source: Skill.Source
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
      isUserInvocable: isUserInvocable(description: description)
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
}
