import Foundation

/// A coding-agent CLI that Supacool can spawn inside a terminal session.
///
/// Migrated from a closed enum to a struct keyed by stable string id so that
/// new built-in agents (pi) and user-defined agents can be added without
/// modifying every switch site. Shell-launching is template-driven; UI
/// metadata (icon / tint) lives on the struct directly.
///
/// Wire format unchanged from the previous enum: `Codable` writes a single
/// string id. Old persisted sessions whose `agent` value is `"claude"` /
/// `"codex"` decode without any migration step. Unknown ids decode to a
/// synthetic placeholder (see `AgentRegistry.lookupOrPlaceholder`) so a
/// removed user-defined agent doesn't make the whole sessions file fail.
nonisolated struct AgentType: Hashable, Codable, Sendable, Identifiable {
  /// Stable identifier. For built-ins: `"claude"`, `"codex"`, `"pi"`. For
  /// user-defined agents: a slug chosen by the user.
  let id: String
  let displayName: String
  let binary: String

  /// CLI flag that turns off permission/approval prompts. `nil` for agents
  /// (like pi) that have no permission popups by design.
  let bypassPermissionsFlag: String?

  /// True for agents with a dedicated interactive plan mode (currently only
  /// Claude Code via `--permission-mode plan`).
  let supportsPlanMode: Bool

  /// How the card / picker render this agent visually.
  let icon: AgentIcon
  let tintColorName: String

  /// Shell command templates. `{binary}`, `{prompt}`, `{flags}`, `{id}`
  /// are the only placeholders. `{prompt}` is shell-quoted by the caller.
  let launchTemplate: String
  let resumeTemplate: String?
  let resumePickerTemplate: String?

  /// Slash/sigil-style skill autocomplete. `nil` for agents with no skill
  /// concept Supacool understands.
  let skillSyntax: AgentSkillSyntax?

  /// `true` for the three first-party entries seeded by `AgentRegistry`;
  /// `false` for user-configured agents. Used by the Settings UI to
  /// distinguish editable rows from read-only ones.
  let isBuiltin: Bool

  // MARK: - Codable

  // Serialized form: a single string (the id). Deserialized form: the
  // full struct, looked up via `AgentRegistry`. This keeps wire format
  // backward-compatible with the prior enum (which encoded its raw value)
  // and forward-compatible with user-defined agents that may not exist in
  // every install.

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let id = try container.decode(String.self)
    self = AgentRegistry.lookupOrPlaceholder(for: id)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(id)
  }

  // MARK: - Static accessors for built-ins

  // These call into AgentRegistry which holds the canonical instances.
  // Force-unwraps are safe — built-in ids are seeded at type init.
  static var claude: AgentType { AgentRegistry.builtin(id: "claude") }
  static var codex: AgentType { AgentRegistry.builtin(id: "codex") }
  static var pi: AgentType { AgentRegistry.builtin(id: "pi") }

  // MARK: - Display

  static func displayName(for agent: AgentType?) -> String {
    agent?.displayName ?? "Shell"
  }

  // MARK: - Memberwise init

  init(
    id: String,
    displayName: String,
    binary: String,
    bypassPermissionsFlag: String?,
    supportsPlanMode: Bool,
    icon: AgentIcon,
    tintColorName: String,
    launchTemplate: String = "{binary}{flags} {prompt}",
    resumeTemplate: String? = nil,
    resumePickerTemplate: String? = nil,
    skillSyntax: AgentSkillSyntax? = nil,
    isBuiltin: Bool = false
  ) {
    self.id = id
    self.displayName = displayName
    self.binary = binary
    self.bypassPermissionsFlag = bypassPermissionsFlag
    self.supportsPlanMode = supportsPlanMode
    self.icon = icon
    self.tintColorName = tintColorName
    self.launchTemplate = launchTemplate
    self.resumeTemplate = resumeTemplate
    self.resumePickerTemplate = resumePickerTemplate
    self.skillSyntax = skillSyntax
    self.isBuiltin = isBuiltin
  }

  // MARK: - Shell command rendering

  /// Shell command used to launch the agent with an initial prompt.
  /// The string is what we type into the terminal (newline appended by caller).
  func command(
    prompt: String,
    bypassPermissions: Bool = false,
    planMode: Bool = false
  ) -> String {
    let flagFragment = renderFlags(bypassPermissions: bypassPermissions, planMode: planMode)
    return launchTemplate
      .replacingOccurrences(of: "{binary}", with: binary)
      .replacingOccurrences(of: "{flags}", with: flagFragment)
      .replacingOccurrences(of: "{prompt}", with: Self.shellQuote(prompt))
  }

  /// Command used when no prompt is provided.
  func commandWithoutPrompt(
    bypassPermissions: Bool = false,
    planMode: Bool = false
  ) -> String {
    let flagFragment = renderFlags(bypassPermissions: bypassPermissions, planMode: planMode)
    // Drop the `{prompt}` placeholder along with any leading whitespace so
    // the rendered string doesn't end with a stray space.
    let stripped = launchTemplate
      .replacingOccurrences(of: " {prompt}", with: "")
      .replacingOccurrences(of: "{prompt}", with: "")
    return stripped
      .replacingOccurrences(of: "{binary}", with: binary)
      .replacingOccurrences(of: "{flags}", with: flagFragment)
      .trimmingCharacters(in: .whitespaces)
  }

  /// Shell command that resumes a prior session by its agent-native id.
  /// Returns `nil` if the agent has no resume-by-id template configured.
  func resumeCommand(sessionID: String, bypassPermissions: Bool = false) -> String? {
    guard let template = resumeTemplate else { return nil }
    let flagFragment = renderFlags(bypassPermissions: bypassPermissions, planMode: false)
    return template
      .replacingOccurrences(of: "{binary}", with: binary)
      .replacingOccurrences(of: "{flags}", with: flagFragment)
      .replacingOccurrences(of: "{id}", with: Self.shellQuote(sessionID))
  }

  /// Shell command that launches the agent's built-in resume picker for the
  /// current directory (no session id). `nil` when the agent has no picker
  /// concept Supacool can invoke.
  func resumePickerCommand(bypassPermissions: Bool = false) -> String? {
    guard let template = resumePickerTemplate else { return nil }
    let flagFragment = renderFlags(bypassPermissions: bypassPermissions, planMode: false)
    return template
      .replacingOccurrences(of: "{binary}", with: binary)
      .replacingOccurrences(of: "{flags}", with: flagFragment)
  }

  /// Builds the leading-space-prefixed flag fragment used by the templates
  /// (`" --dangerously-skip-permissions"` or `""`). Plan mode wins over
  /// bypass-permissions so the two never conflict in the rendered command.
  /// Agents without a `bypassPermissionsFlag` silently drop the bypass
  /// request — same for plan mode on agents that don't support it.
  private func renderFlags(bypassPermissions: Bool, planMode: Bool) -> String {
    if planMode, supportsPlanMode {
      return " --permission-mode plan"
    }
    if bypassPermissions, let flag = bypassPermissionsFlag {
      return " \(flag)"
    }
    return ""
  }

  /// Single-quote escape: wraps the input in `'...'`, replacing any embedded
  /// single quotes with the POSIX escape sequence `'\''`.
  nonisolated static func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}

/// How the card and picker render an agent.
nonisolated enum AgentIcon: Hashable, Codable, Sendable {
  /// Bundled asset catalog name (e.g. `"agent-icon-claude"`). Used for the
  /// three first-party agents whose vendor logos ship with the app.
  case asset(String)
  /// SF Symbol name. Used for user-defined custom agents.
  case symbol(String)
}

/// Skill autocomplete trigger semantics. Claude uses `/`, Codex uses `$`.
/// Pi has its own `/skill:` syntax that needs a different parser; until
/// that's wired up pi's `skillSyntax` stays `nil`.
nonisolated struct AgentSkillSyntax: Hashable, Codable, Sendable {
  /// String the user types to open the autocomplete popover. Always a
  /// single character today (`"/"` or `"$"`), but kept as a `String` so
  /// `Codable` synthesis works without a custom encoder.
  let triggerString: String
  /// True when the agent distinguishes user-invocable skills (e.g. Claude's
  /// "Slash Commands" vs. "Agent Skills" sections in the popover).
  let separatesUserInvocable: Bool

  init(triggerString: String, separatesUserInvocable: Bool) {
    self.triggerString = triggerString
    self.separatesUserInvocable = separatesUserInvocable
  }

  /// Convenience init for the common single-character trigger.
  init(triggerCharacter: Character, separatesUserInvocable: Bool) {
    self.init(triggerString: String(triggerCharacter), separatesUserInvocable: separatesUserInvocable)
  }

  /// First character of the trigger string, used by the autocomplete
  /// popover's keystroke-watching code.
  var triggerCharacter: Character {
    triggerString.first ?? "/"
  }
}
