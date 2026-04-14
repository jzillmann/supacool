import Foundation

/// A coding-agent CLI that Supacool can spawn inside a terminal session.
nonisolated enum AgentType: String, CaseIterable, Codable, Sendable, Identifiable {
  case claude
  case codex

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .claude: "Claude Code"
    case .codex: "Codex"
    }
  }

  /// Display label for an optional agent, where `nil` means a raw shell
  /// session (no agent CLI invoked).
  static func displayName(for agent: AgentType?) -> String {
    agent?.displayName ?? "Shell"
  }

  /// CLI flag that skips permission / approval prompts so the agent can act
  /// autonomously. Same semantic for both CLIs even though the flag spelling
  /// differs. Supacool defaults this on — users opt out via the sheet.
  var bypassPermissionsFlag: String {
    switch self {
    case .claude: "--dangerously-skip-permissions"
    case .codex: "--dangerously-bypass-approvals-and-sandbox"
    }
  }

  /// Shell command used to launch the agent with an initial prompt.
  /// The string is what we type into the terminal (newline appended by caller).
  func command(prompt: String, bypassPermissions: Bool = false) -> String {
    let flag = bypassPermissions ? " \(bypassPermissionsFlag)" : ""
    return "\(binary)\(flag) \(Self.shellQuote(prompt))"
  }

  /// Command used when no prompt is provided.
  func commandWithoutPrompt(bypassPermissions: Bool = false) -> String {
    bypassPermissions ? "\(binary) \(bypassPermissionsFlag)" : binary
  }

  /// Shell command that resumes a prior session by its agent-native id.
  /// Claude Code: `claude --resume <id>`. Codex: `codex resume <id>`.
  func resumeCommand(sessionID: String) -> String {
    let quoted = Self.shellQuote(sessionID)
    switch self {
    case .claude: return "\(binary) --resume \(quoted)"
    case .codex: return "\(binary) resume \(quoted)"
    }
  }

  /// Shell command that launches the agent's built-in resume picker for the
  /// current directory (no session id). Used when Supacool never captured an
  /// agent-native session id (hook not installed / pre-hook session).
  /// Claude Code: `claude --resume`. Codex: `codex resume`.
  var resumePickerCommand: String {
    switch self {
    case .claude: return "\(binary) --resume"
    case .codex: return "\(binary) resume"
    }
  }

  private var binary: String {
    switch self {
    case .claude: "claude"
    case .codex: "codex"
    }
  }

  /// Single-quote escape: wraps the input in `'...'`, replacing any embedded
  /// single quotes with the POSIX escape sequence `'\''`.
  nonisolated static func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
