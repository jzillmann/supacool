import Foundation
import Testing

@testable import Supacool

/// Locks the shape of the remote hook-install snippet. A quiet
/// regression here means the reverse socket tunnel is live but
/// nothing's firing into it — remote cards silently stop updating
/// busy/awaiting-input state. Worth unit-testing.
struct RemoteHookInstallerTests {

  @Test func claudeSnippetTargetsClaudeSettingsPath() throws {
    let snippet = try #require(RemoteHookInstaller.bootstrapSnippet(for: .claude))
    #expect(snippet.contains("$HOME/.claude/settings.json"))
  }

  @Test func codexSnippetTargetsCodexHooksPath() throws {
    let snippet = try #require(RemoteHookInstaller.bootstrapSnippet(for: .codex))
    #expect(snippet.contains("$HOME/.codex/hooks.json"))
  }

  @Test func snippetEmbedsHooksAsBase64SoQuotingStaysFlat() throws {
    // The hook JSON embeds nested quotes, slashes, and `$`-vars — all of
    // which would be brittle to escape through base64 → bash → ssh →
    // Ghostty layers. Base64 encoding is the invariant we rely on.
    let snippet = try #require(RemoteHookInstaller.bootstrapSnippet(for: .claude))
    #expect(snippet.contains("SUPACOOL_HOOK_B64="))
    #expect(snippet.contains("base64.b64decode"))
  }

  @Test func snippetUsesPython3ForTheMerge() throws {
    let snippet = try #require(RemoteHookInstaller.bootstrapSnippet(for: .claude))
    #expect(snippet.contains("command -v python3"))
    #expect(snippet.contains("python3 - "))
  }

  @Test func snippetPrunesPreviouslyInstalledSupacoolGroups() throws {
    // Reconnect-after-reconnect would otherwise stack duplicate groups
    // into the same event's array forever. The merge script filters
    // groups whose sole command is one of ours before appending.
    let snippet = try #require(RemoteHookInstaller.bootstrapSnippet(for: .claude))
    #expect(snippet.contains("our_cmds"))
    #expect(snippet.contains("all(c in our_cmds for c in cmds)"))
  }

  @Test func snippetExitsCleanlyWithoutPython3() throws {
    // `|| true` on the python invocation + the else-branch echo keep
    // the bootstrap flowing into the tmux exec even when the host is
    // missing python3 — the session still spawns, just without
    // busy/awaiting-input board state.
    let snippet = try #require(RemoteHookInstaller.bootstrapSnippet(for: .claude))
    #expect(snippet.contains("|| true"))
    #expect(snippet.contains("skipping hook install"))
  }

  // MARK: - Integration with bootstrap

  @Test func bootstrapScriptIncludesHookInstallForAgent() {
    let script = renderBootstrapScript(agentCommand: "claude code", agent: .claude)
    #expect(script.contains("SUPACOOL_HOOK_B64="))
    #expect(script.contains("$HOME/.claude/settings.json"))
  }

  @Test func bootstrapScriptOmitsHookInstallForShellSession() {
    let script = renderBootstrapScript(agentCommand: nil, agent: nil)
    #expect(!script.contains("SUPACOOL_HOOK_B64="))
    #expect(!script.contains("python3"))
  }
}
