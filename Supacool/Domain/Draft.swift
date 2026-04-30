import Foundation

/// A half-finished "new terminal" prompt the user wanted to come back to.
/// Sits in `@Shared(.drafts)` and surfaces as a slim row at the top of
/// the Matrix Board. Tap → reopens NewTerminalSheet pre-filled with the
/// draft's contents. Launching the sheet (Create) consumes the draft;
/// Save Draft updates it in-place.
///
/// Drafts intentionally model **less** than `Bookmark`:
/// - No `name` — the prompt's first line is the label.
/// - `repositoryID` is optional. The sheet always picks a default repo on
///   open, but a draft can outlive the repo it was created against (e.g.
///   the user removed that repo from settings); we preserve the prompt
///   in that case rather than dropping it on the floor.
/// - `workspaceQuery` is the free-text the user typed in the workspace
///   field, not a resolved `WorkspaceSelection`. We re-infer the selection
///   on resume against the *current* branch list, which may have changed.
/// - Local-only for v1 — drafts don't carry remote-host / repository-
///   remote-target plumbing. Remote support can land later if anyone uses
///   drafts for ssh sessions in practice.
///
/// Persistence: forward-compatible Codable per `docs/agent-guides/persistence.md`.
/// Every field except the identity quartet decodes via `decodeIfPresent ?? default`.
nonisolated struct Draft: Identifiable, Equatable, Hashable, Codable, Sendable {
  let id: UUID
  /// Optional — when nil, the sheet falls back to its usual repo-picker
  /// default (filtered preferred, then first available).
  var repositoryID: String?
  /// Prompt body. May be empty — a draft of "claude on repo X with a
  /// fresh branch but no prompt yet" is still useful as a one-tap setup.
  var prompt: String
  /// `nil` = raw shell session (no agent CLI invoked).
  var agent: AgentType?
  /// Free-text contents of the workspace field at save-time. Re-inferred
  /// into a `WorkspaceSelection` on resume against the current branch list.
  var workspaceQuery: String
  var planMode: Bool
  let createdAt: Date
  var updatedAt: Date

  init(
    id: UUID = UUID(),
    repositoryID: String? = nil,
    prompt: String = "",
    agent: AgentType? = .claude,
    workspaceQuery: String = "",
    planMode: Bool = false,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.repositoryID = repositoryID
    self.prompt = prompt
    self.agent = agent
    self.workspaceQuery = workspaceQuery
    self.planMode = planMode
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  // MARK: - Codable (forward-compatible)

  enum CodingKeys: String, CodingKey {
    case id, repositoryID, prompt, agent, workspaceQuery, planMode, createdAt, updatedAt
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(UUID.self, forKey: .id)
    repositoryID = try c.decodeIfPresent(String.self, forKey: .repositoryID)
    prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
    agent = try c.decodeIfPresent(AgentType.self, forKey: .agent)
    workspaceQuery = try c.decodeIfPresent(String.self, forKey: .workspaceQuery) ?? ""
    planMode = try c.decodeIfPresent(Bool.self, forKey: .planMode) ?? false
    createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
  }

  // MARK: - Display

  /// Human-friendly label for the pill: first non-empty line of the
  /// prompt, trimmed. Falls back to a dim placeholder when the prompt is
  /// empty so empty drafts are still tappable.
  var displayLabel: String {
    let firstLine =
      prompt
      .split(whereSeparator: \.isNewline)
      .first
      .map(String.init)?
      .trimmingCharacters(in: .whitespaces)
      ?? ""
    return firstLine.isEmpty ? "Untitled draft" : firstLine
  }
}
