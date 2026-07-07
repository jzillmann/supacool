import Foundation
import Testing

@testable import Supacool

@MainActor
struct AgentRegistryTests {
  // MARK: - Built-in lookup

  @Test func builtinIDsAreRegistered() {
    #expect(AgentRegistry.entry(forID: "claude") != nil)
    #expect(AgentRegistry.entry(forID: "codex") != nil)
    #expect(AgentRegistry.entry(forID: "pi") != nil)
  }

  @Test func staticAccessorsResolveToBuiltins() {
    #expect(AgentType.claude.id == "claude")
    #expect(AgentType.codex.id == "codex")
    #expect(AgentType.pi.id == "pi")
    #expect(AgentType.claude.isBuiltin)
    #expect(AgentType.codex.isBuiltin)
    #expect(AgentType.pi.isBuiltin)
  }

  @Test func allAgentsIncludesEveryBuiltin() {
    let ids = AgentRegistry.allAgents.map(\.id)
    #expect(Set(ids).isSuperset(of: ["claude", "codex", "pi"]))
  }

  // MARK: - Pi-specific shape

  @Test func piHasNoBypassFlagAndNoPlanMode() {
    let piAgent = AgentType.pi
    #expect(piAgent.bypassPermissionsFlag == nil)
    #expect(piAgent.supportsPlanMode == false)
    #expect(piAgent.skillSyntax == nil)
  }

  @Test func piResumeTemplatesUseSingleDashSession() {
    let resume = AgentType.pi.resumeCommand(sessionID: "abc")
    #expect(resume == "pi --session 'abc'")

    let picker = AgentType.pi.resumePickerCommand()
    #expect(picker == "pi -r")
  }

  // MARK: - Codable migration

  @Test func decodesLegacyClaudeStringFromOldOnDiskData() throws {
    // Old enum encoding: a single string raw value.
    let data = Data("\"claude\"".utf8)
    let agent = try JSONDecoder().decode(AgentType.self, from: data)
    #expect(agent.id == "claude")
    #expect(agent.binary == "claude")
    #expect(agent.isBuiltin)
  }

  @Test func decodesLegacyCodexStringFromOldOnDiskData() throws {
    let data = Data("\"codex\"".utf8)
    let agent = try JSONDecoder().decode(AgentType.self, from: data)
    #expect(agent.id == "codex")
    #expect(agent.isBuiltin)
  }

  @Test func unknownIDDecodesToPlaceholderInsteadOfThrowing() throws {
    let data = Data("\"my-removed-agent\"".utf8)
    let agent = try JSONDecoder().decode(AgentType.self, from: data)
    #expect(agent.id == "my-removed-agent")
    #expect(agent.isBuiltin == false)
    #expect(agent.binary == "my-removed-agent")
    #expect(agent.bypassPermissionsFlag == nil)
    #expect(agent.supportsPlanMode == false)
    #expect(agent.resumeTemplate == nil)
  }

  @Test func encodingProducesJustTheID() throws {
    let encoded = try JSONEncoder().encode(AgentType.pi)
    #expect(String(data: encoded, encoding: .utf8) == "\"pi\"")
  }

  @Test func encodeDecodeRoundTripPreservesIdentity() throws {
    let original = AgentType.codex
    let data = try JSONEncoder().encode(original)
    let restored = try JSONDecoder().decode(AgentType.self, from: data)
    #expect(restored == original)
  }

  // MARK: - Template rendering

  @Test func claudeRendersBypassFlagBeforePrompt() {
    let cmd = AgentType.claude.command(prompt: "hello", bypassPermissions: true)
    #expect(cmd == "claude --dangerously-skip-permissions 'hello'")
  }

  @Test func claudePlanModeOverridesBypassFlag() {
    let cmd = AgentType.claude.command(
      prompt: "design system",
      bypassPermissions: true,
      planMode: true
    )
    #expect(cmd == "claude --permission-mode plan 'design system'")
  }

  @Test func claudeAppendsRemoteControlFlagAfterPermissionFlag() {
    let cmd = AgentType.claude.command(
      prompt: "ship it",
      bypassPermissions: true,
      remoteControl: true
    )
    #expect(cmd == "claude --dangerously-skip-permissions --remote-control 'ship it'")
  }

  @Test func claudeRemoteControlCombinesWithPlanMode() {
    let cmd = AgentType.claude.command(
      prompt: "design",
      bypassPermissions: true,
      planMode: true,
      remoteControl: true
    )
    // Plan wins over bypass; remote-control is orthogonal and still appends.
    #expect(cmd == "claude --permission-mode plan --remote-control 'design'")
  }

  @Test func claudeRemoteControlShellQuotesOptionalName() {
    let cmd = AgentType.claude.command(
      prompt: "go",
      remoteControl: true,
      remoteControlName: "My Project"
    )
    #expect(cmd == "claude --remote-control 'My Project' 'go'")
  }

  @Test func claudeRemoteControlBlankNameOmitsName() {
    let cmd = AgentType.claude.command(
      prompt: "go",
      remoteControl: true,
      remoteControlName: "   "
    )
    #expect(cmd == "claude --remote-control 'go'")
  }

  @Test func claudeSupportsRemoteControlCodexAndPiDoNot() {
    #expect(AgentType.claude.supportsRemoteControl)
    #expect(AgentType.claude.remoteControlFlag == "--remote-control")
    #expect(AgentType.codex.supportsRemoteControl == false)
    #expect(AgentType.pi.supportsRemoteControl == false)
  }

  @Test func codexSilentlyDropsRemoteControlWhenUnsupported() {
    let cmd = AgentType.codex.command(prompt: "hi", remoteControl: true)
    #expect(cmd == "codex 'hi'")
  }

  @Test func piSilentlyDropsBypassFlagWhenAgentHasNone() {
    let cmd = AgentType.pi.command(prompt: "hi", bypassPermissions: true)
    #expect(cmd == "pi 'hi'")
  }

  @Test func piCommandWithoutPromptRendersBareBinary() {
    let cmd = AgentType.pi.commandWithoutPrompt(bypassPermissions: true)
    #expect(cmd == "pi")
  }

  @Test func codexResumeAppendsBypassFlag() {
    let cmd = AgentType.codex.resumeCommand(sessionID: "abc-123", bypassPermissions: true)
    #expect(cmd == "codex resume 'abc-123' --dangerously-bypass-approvals-and-sandbox")
  }

  @Test func placeholderAgentHasNoResumeCommand() {
    let placeholder = AgentRegistry.lookupOrPlaceholder(for: "ghost")
    #expect(placeholder.resumeCommand(sessionID: "x") == nil)
    #expect(placeholder.resumePickerCommand() == nil)
  }

  @Test func shellQuoteEscapesEmbeddedSingleQuotes() {
    let cmd = AgentType.claude.command(prompt: "it's fine")
    // POSIX `'\''` escape inside the single-quoted wrapper.
    #expect(cmd == "claude 'it'\\''s fine'")
  }

  // MARK: - Model flag

  @Test func claudeAndCodexSupportModelSelectionPiDoesNot() {
    #expect(AgentType.claude.supportsModelSelection)
    #expect(AgentType.claude.modelFlag == "--model")
    #expect(AgentType.codex.supportsModelSelection)
    #expect(AgentType.codex.modelFlag == "-m")
    #expect(AgentType.pi.supportsModelSelection == false)
  }

  @Test func claudeRendersModelFlagAfterPermissionFlags() {
    let cmd = AgentType.claude.command(
      prompt: "hello",
      bypassPermissions: true,
      model: "opus"
    )
    #expect(cmd == "claude --dangerously-skip-permissions --model 'opus' 'hello'")
  }

  @Test func nilModelRendersNoModelFlag() {
    let cmd = AgentType.claude.command(prompt: "hello", model: nil)
    #expect(cmd == "claude 'hello'")
  }

  @Test func blankModelRendersNoModelFlag() {
    let cmd = AgentType.claude.command(prompt: "hello", model: "   ")
    #expect(cmd == "claude 'hello'")
  }

  @Test func codexRendersShortModelFlag() {
    let cmd = AgentType.codex.command(prompt: "hi", model: "gpt-5.1-codex")
    #expect(cmd == "codex -m 'gpt-5.1-codex' 'hi'")
  }

  @Test func piSilentlyDropsModelWhenAgentHasNoFlag() {
    let cmd = AgentType.pi.command(prompt: "hi", model: "gpt-5")
    #expect(cmd == "pi 'hi'")
  }

  @Test func claudeResumeAppendsModelFlag() {
    let cmd = AgentType.claude.resumeCommand(
      sessionID: "abc-123",
      bypassPermissions: true,
      model: "sonnet"
    )
    #expect(cmd == "claude --resume 'abc-123' --dangerously-skip-permissions --model 'sonnet'")
  }

  @Test func commandWithoutPromptRendersModelFlag() {
    let cmd = AgentType.claude.commandWithoutPrompt(model: "haiku")
    #expect(cmd == "claude --model 'haiku'")
  }

  // MARK: - Additional directories (--add-dir)

  @Test func claudeExposesAddDirFlagCodexAndPiDoNot() {
    #expect(AgentType.claude.additionalDirsFlag == "--add-dir")
    #expect(AgentType.codex.additionalDirsFlag == nil)
    #expect(AgentType.pi.additionalDirsFlag == nil)
  }

  @Test func claudeRendersAddDirAfterOtherFlagsBeforePrompt() {
    let cmd = AgentType.claude.command(
      prompt: "go",
      additionalDirectories: ["/Users/me/.supacool/repos/acme"]
    )
    #expect(cmd == "claude --add-dir '/Users/me/.supacool/repos/acme' 'go'")
  }

  @Test func claudeRendersMultipleAddDirPathsUnderSingleFlag() {
    let cmd = AgentType.claude.command(
      prompt: "go",
      additionalDirectories: ["/a/b", "/c/d"]
    )
    #expect(cmd == "claude --add-dir '/a/b' '/c/d' 'go'")
  }

  @Test func addDirCombinesWithPermissionAndModelFlags() {
    let cmd = AgentType.claude.command(
      prompt: "go",
      bypassPermissions: true,
      model: "opus",
      additionalDirectories: ["/a/b"]
    )
    #expect(cmd == "claude --dangerously-skip-permissions --model 'opus' --add-dir '/a/b' 'go'")
  }

  @Test func emptyAdditionalDirectoriesRenderNoFlag() {
    let cmd = AgentType.claude.command(prompt: "go", additionalDirectories: [])
    #expect(cmd == "claude 'go'")
  }

  @Test func blankAdditionalDirectoriesAreDropped() {
    let cmd = AgentType.claude.command(prompt: "go", additionalDirectories: ["   ", ""])
    #expect(cmd == "claude 'go'")
  }

  @Test func addDirShellQuotesPathsWithSpaces() {
    let cmd = AgentType.claude.command(
      prompt: "go",
      additionalDirectories: ["/Users/me/My Repos/acme"]
    )
    #expect(cmd == "claude --add-dir '/Users/me/My Repos/acme' 'go'")
  }

  @Test func codexSilentlyDropsAdditionalDirectories() {
    let cmd = AgentType.codex.command(prompt: "hi", additionalDirectories: ["/a/b"])
    #expect(cmd == "codex 'hi'")
  }

  @Test func piSilentlyDropsAdditionalDirectories() {
    let cmd = AgentType.pi.command(prompt: "hi", additionalDirectories: ["/a/b"])
    #expect(cmd == "pi 'hi'")
  }

  @Test func commandWithoutPromptRendersAddDir() {
    let cmd = AgentType.claude.commandWithoutPrompt(additionalDirectories: ["/a/b"])
    #expect(cmd == "claude --add-dir '/a/b'")
  }

  @Test func claudeResumeAppendsAddDir() {
    let cmd = AgentType.claude.resumeCommand(
      sessionID: "abc-123",
      additionalDirectories: ["/a/b"]
    )
    #expect(cmd == "claude --resume 'abc-123' --add-dir '/a/b'")
  }
}
