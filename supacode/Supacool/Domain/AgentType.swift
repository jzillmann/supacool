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

  /// Shell command used to launch the agent with an initial prompt.
  /// The string is what we type into the terminal (newline appended by caller).
  func command(prompt: String) -> String {
    "\(binary) \(Self.shellQuote(prompt))"
  }

  /// Command used when no prompt is provided (rare — we always have a prompt in v1).
  var commandWithoutPrompt: String { binary }

  /// Shell command that resumes a prior session by its agent-native id.
  /// Claude Code: `claude --resume <id>`. Codex: `codex resume <id>`.
  func resumeCommand(sessionID: String) -> String {
    let quoted = Self.shellQuote(sessionID)
    switch self {
    case .claude: return "\(binary) --resume \(quoted)"
    case .codex: return "\(binary) resume \(quoted)"
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
