import Foundation

/// Resolves the *saved default model* an agent CLI uses when Supacool launches
/// it with no explicit `--model` flag — i.e. when the New Terminal "Model"
/// picker is left on "Default". Surfacing this (e.g. "Default (opus[1m])") makes
/// a session that would silently inherit an expensive saved default visible
/// before launch, instead of only discovering it after the credits are gone.
///
/// Reads the agent's own on-disk config, so it reflects whatever the user last
/// set via the CLI (for Claude Code, an in-session `/model <name>` persists to
/// `~/.claude/settings.json`). Returns `nil` when there's no discoverable
/// default — config missing, key absent/`null`, or an agent whose config we
/// don't parse yet — and the picker falls back to a plain "Default" label.
enum AgentDefaultModel {
  static func resolve(for agent: AgentType) async -> String? {
    switch agent.id {
    case "claude": return readClaudeDefault()
    default: return nil
    }
  }

  /// `~/.claude/settings.json` → top-level `"model"` string (stable aliases like
  /// `opus[1m]` / `sonnet` / `fable`, or a dated id). Absent, `null`, or empty → nil.
  private static func readClaudeDefault() -> String? {
    let url = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".claude/settings.json", directoryHint: .notDirectory)
    guard
      let data = try? Data(contentsOf: url),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let model = json["model"] as? String,
      !model.isEmpty
    else { return nil }
    return model
  }
}
