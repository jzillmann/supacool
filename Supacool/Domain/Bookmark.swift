import Foundation

/// A saved "new terminal" template: one-click launch for a recurring
/// task (e.g. `/ci-triage regression`, `/investigate`). Bookmarks are
/// per-repo — a `[Bookmark]` flat array with a `repositoryID` field on
/// each item, mirroring the `[AgentSession]` convention.
///
/// Persistence: forward-compatible Codable per `docs/agent-guides/persistence.md`.
/// Every field except the identity quartet decodes via `decodeIfPresent ?? default`.
nonisolated struct Bookmark: Identifiable, Equatable, Hashable, Codable, Sendable {
  let id: UUID
  /// Scopes the bookmark to a repository. Matches `Repository.ID`
  /// (repository root URL path).
  let repositoryID: String
  var name: String
  /// The prompt text fed to the agent CLI on launch. Slash-commands
  /// (`/investigate`, `/ci-triage …`) are not parsed here — the agent
  /// interprets them at runtime.
  var prompt: String
  /// `nil` = raw shell session (no agent CLI invoked).
  var agent: AgentType?
  var worktreeMode: WorktreeMode
  var planMode: Bool
  let createdAt: Date

  /// Whether clicking the bookmark creates a fresh worktree or runs at
  /// the repo root. Read-only tasks (investigate / ask-a-question) want
  /// `.repoRoot` so they don't pollute the worktree list per click.
  nonisolated enum WorktreeMode: String, Codable, Sendable {
    case newWorktree
    case repoRoot
  }

  init(
    id: UUID = UUID(),
    repositoryID: String,
    name: String,
    prompt: String,
    agent: AgentType? = .claude,
    worktreeMode: WorktreeMode = .repoRoot,
    planMode: Bool = false,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.repositoryID = repositoryID
    self.name = name
    self.prompt = prompt
    self.agent = agent
    self.worktreeMode = worktreeMode
    self.planMode = planMode
    self.createdAt = createdAt
  }

  // MARK: - Codable (forward-compatible)

  enum CodingKeys: String, CodingKey {
    case id, repositoryID, name, prompt, agent, worktreeMode, planMode, createdAt
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(UUID.self, forKey: .id)
    repositoryID = try c.decode(String.self, forKey: .repositoryID)
    name = try c.decode(String.self, forKey: .name)
    prompt = try c.decode(String.self, forKey: .prompt)
    agent = try c.decodeIfPresent(AgentType.self, forKey: .agent)
    worktreeMode =
      try c.decodeIfPresent(WorktreeMode.self, forKey: .worktreeMode) ?? .repoRoot
    planMode = try c.decodeIfPresent(Bool.self, forKey: .planMode) ?? false
    createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
  }

  // MARK: - Worktree naming

  /// Produces a unique worktree name for a `.newWorktree`-mode launch:
  /// slugified bookmark name + timestamp. Uniqueness isn't cryptographic
  /// — the minute-granularity stamp is enough for human-paced clicks.
  /// Collisions within a minute are rare and would surface as a git
  /// error the user can retry through.
  func generateWorktreeName(now: Date) -> String {
    let slug = Self.slugify(name)
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmm"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    let stamp = formatter.string(from: now)
    let root = slug.isEmpty ? "bookmark" : slug
    return "\(root)-\(stamp)"
  }

  nonisolated static func slugify(_ input: String) -> String {
    let lower = input.lowercased()
    var result = ""
    var lastWasHyphen = false
    for character in lower {
      if character.isLetter || character.isNumber {
        result.append(character)
        lastWasHyphen = false
      } else if !lastWasHyphen {
        result.append("-")
        lastWasHyphen = true
      }
    }
    // Trim leading/trailing hyphens.
    while result.hasPrefix("-") { result.removeFirst() }
    while result.hasSuffix("-") { result.removeLast() }
    return result
  }
}
