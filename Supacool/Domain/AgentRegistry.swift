import Foundation

/// Single source of truth for the set of available `AgentType` instances.
///
/// PR 1 ships the three first-party agents only (Claude / Codex / Pi).
/// User-defined agents will plug into `userDefined` (today empty) without
/// changing any other call site.
nonisolated enum AgentRegistry {
  /// All agents, built-ins first then user-defined (sorted by display
  /// name). Used by the New Terminal sheet picker and the Settings list.
  static var allAgents: [AgentType] {
    builtins + userDefined.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
  }

  /// Convenience for lookups in views and tests.
  static func entry(forID id: String) -> AgentType? {
    if let builtin = builtinByID[id] { return builtin }
    return userDefined.first { $0.id == id }
  }

  /// Used by `AgentType.init(from decoder:)` to resolve a stored id back
  /// into a full struct. Unknown ids return a synthetic placeholder so a
  /// removed user-defined agent doesn't fail decode of the entire sessions
  /// file. Placeholder entries can't successfully spawn (binary stays the
  /// id) but render with their id as the display name so the user can spot
  /// them and re-add the missing config.
  static func lookupOrPlaceholder(for id: String) -> AgentType {
    if let entry = entry(forID: id) { return entry }
    return AgentType(
      id: id,
      displayName: id,
      binary: id,
      bypassPermissionsFlag: nil,
      supportsPlanMode: false,
      icon: .symbol("questionmark.circle"),
      tintColorName: "secondary",
      launchTemplate: "{binary}{flags} {prompt}",
      resumeTemplate: nil,
      resumePickerTemplate: nil,
      skillSyntax: nil,
      isBuiltin: false
    )
  }

  /// Force-unwrap accessor for the static `AgentType.claude / .codex / .pi`
  /// computed properties. Crashes only if a built-in id is misspelled in
  /// this file — caught immediately on first launch in development.
  static func builtin(id: String) -> AgentType {
    guard let entry = builtinByID[id] else {
      preconditionFailure("AgentRegistry: missing built-in id \"\(id)\"")
    }
    return entry
  }

  // MARK: - Built-ins

  private static let builtins: [AgentType] = [claudeBuiltin, codexBuiltin, piBuiltin]

  private static let builtinByID: [String: AgentType] = Dictionary(
    uniqueKeysWithValues: builtins.map { ($0.id, $0) }
  )

  // Icons: SF Symbols for now. A follow-up commit replaces these with
  // bundled vendor logos (Anthropic burst, OpenAI mark, pi.dev/logo.svg)
  // in an AgentIcons.xcassets catalog — registry stays the same shape,
  // the entries flip from `.symbol` to `.asset` when assets land.
  private static let claudeBuiltin = AgentType(
    id: "claude",
    displayName: "Claude Code",
    binary: "claude",
    bypassPermissionsFlag: "--dangerously-skip-permissions",
    supportsPlanMode: true,
    icon: .symbol("brain"),
    tintColorName: "purple",
    launchTemplate: "{binary}{flags} {prompt}",
    resumeTemplate: "{binary} --resume {id}{flags}",
    resumePickerTemplate: "{binary} --resume{flags}",
    skillSyntax: AgentSkillSyntax(triggerCharacter: "/", separatesUserInvocable: true),
    isBuiltin: true
  )

  private static let codexBuiltin = AgentType(
    id: "codex",
    displayName: "Codex",
    binary: "codex",
    bypassPermissionsFlag: "--dangerously-bypass-approvals-and-sandbox",
    supportsPlanMode: false,
    icon: .symbol("terminal.fill"),
    tintColorName: "cyan",
    launchTemplate: "{binary}{flags} {prompt}",
    resumeTemplate: "{binary} resume {id}{flags}",
    resumePickerTemplate: "{binary} resume{flags}",
    skillSyntax: AgentSkillSyntax(triggerCharacter: "$", separatesUserInvocable: false),
    isBuiltin: true
  )

  // Pi (https://github.com/badlogic/pi-mono):
  // - No `--dangerously-*` flag; pi has no permission popups by design
  //   (extensions can add gates, but vanilla pi just runs).
  // - No interactive plan mode.
  // - Resume is `pi --session <id>`; picker is `pi -r`.
  // - `skillSyntax` left nil for now: pi's `/skill:name` syntax doesn't
  //   match the simple single-character trigger model the existing
  //   autocomplete popover supports. Wiring it up is a follow-up.
  private static let piBuiltin = AgentType(
    id: "pi",
    displayName: "Pi",
    binary: "pi",
    bypassPermissionsFlag: nil,
    supportsPlanMode: false,
    icon: .symbol("circle.hexagongrid.fill"),
    tintColorName: "orange",
    launchTemplate: "{binary}{flags} {prompt}",
    resumeTemplate: "{binary} --session {id}{flags}",
    resumePickerTemplate: "{binary} -r{flags}",
    skillSyntax: nil,
    isBuiltin: true
  )

  // MARK: - User-defined

  // Stub for PR 1 — a follow-up wires this to a `@Shared` storage key.
  // Returning a static empty array keeps the lookup surface stable so
  // call sites don't have to be touched again when the storage lands.
  private static var userDefined: [AgentType] { [] }
}
