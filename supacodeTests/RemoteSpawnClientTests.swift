import Foundation
import Testing

@testable import Supacool

/// Locks the exact shape of the ssh command we hand to Ghostty. These
/// invariants are load-bearing for two reasons:
///
/// 1. A typo in a flag name / SetEnv pair would silently break the hook
///    socket tunnel or the tmux session name — failure modes that only
///    show up at runtime and look like "remote sessions just don't work."
/// 2. The base64 bootstrap is decoded-and-exec'd by the remote shell; if
///    our quoting collapses the single-quote envelope, the remote gets
///    garbage input.
struct RemoteSpawnClientTests {

  // MARK: remoteSpawnShellQuote

  @Test func remoteSpawnShellQuoteReturnsBareFormForSafeStrings() {
    #expect(remoteSpawnShellQuote("simple") == "simple")
    #expect(remoteSpawnShellQuote("a/b/c") == "a/b/c")
    #expect(remoteSpawnShellQuote("name-with_dots.1") == "name-with_dots.1")
    #expect(remoteSpawnShellQuote("SUPACODE_TAB_ID=abc") == "SUPACODE_TAB_ID=abc")
  }

  @Test func remoteSpawnShellQuoteWrapsUnsafeStrings() {
    #expect(remoteSpawnShellQuote("hello world") == "'hello world'")
    #expect(remoteSpawnShellQuote("it's fine") == #"'it'\''s fine'"#)
    #expect(remoteSpawnShellQuote("") == "''")
  }

  // MARK: renderBootstrapScript

  @Test func bootstrapIncludesTmuxAttachOrCreate() {
    let script = renderBootstrapScript(agentCommand: "claude code")
    #expect(script.contains("tmux new-session -A -s"))
    #expect(script.contains("-c \"$SUPACODE_WORKTREE_PATH\""))
    #expect(script.contains("-- claude code"))
  }

  @Test func bootstrapFallsBackWhenNoAgentCommand() {
    let script = renderBootstrapScript(agentCommand: nil)
    #expect(script.contains("tmux new-session -A -s"))
    // No trailing `-- <cmd>` when there's no agent command.
    #expect(!script.contains("-- "))
  }

  @Test func bootstrapClearsStaleSocket() {
    let script = renderBootstrapScript(agentCommand: nil)
    #expect(script.contains(#"rm -f "$SUPACODE_SOCKET_PATH""#))
  }

  @Test func bootstrapCreatesSupacoolDirectories() {
    let script = renderBootstrapScript(agentCommand: nil)
    #expect(script.contains("mkdir -p ~/.supacool/hooks ~/.supacool/ssh"))
  }

  @Test func bootstrapHandlesMissingTerminfo() {
    let script = renderBootstrapScript(agentCommand: nil)
    #expect(script.contains("infocmp xterm-ghostty"))
    #expect(script.contains("export TERM=xterm-256color"))
  }

  // MARK: renderBootstrapCommand

  @Test func bootstrapCommandRoundTripsThroughBase64() throws {
    let command = renderBootstrapCommand(agentCommand: "codex resume x")
    // "echo <base64> | base64 -d | bash -s --"
    let prefix = "echo "
    let suffix = " | base64 -d | bash -s --"
    #expect(command.hasPrefix(prefix))
    #expect(command.hasSuffix(suffix))
    let startIdx = command.index(command.startIndex, offsetBy: prefix.count)
    let endIdx = command.index(command.endIndex, offsetBy: -suffix.count)
    let encoded = String(command[startIdx..<endIdx])
    let decoded = try #require(Data(base64Encoded: encoded))
    let decodedScript = String(data: decoded, encoding: .utf8) ?? ""
    #expect(decodedScript == renderBootstrapScript(agentCommand: "codex resume x"))
  }

  // MARK: renderSSHInvocation

  @Test func invocationIncludesControlMasterAndReverseForward() {
    let inv = sampleInvocation()
    let rendered = renderSSHInvocation(inv)
    #expect(rendered.contains("ControlMaster=auto"))
    #expect(rendered.contains("ControlPath=~/.supacool/ssh/%r@%h:%p"))
    #expect(rendered.contains("ControlPersist=600"))
    #expect(rendered.contains("StreamLocalBindUnlink=yes"))
    // Reverse forward is the remoteSock:localSock pair.
    #expect(rendered.contains("-R /tmp/supacool-hook-xyz.sock:/tmp/supacool-local.sock"))
  }

  @Test func invocationIncludesAllSupacodeEnvVars() {
    let inv = sampleInvocation()
    let rendered = renderSSHInvocation(inv)
    // The SetEnv block combines pairs with spaces inside one arg; we
    // should see them shell-quoted together.
    #expect(rendered.contains("SUPACODE_WORKTREE_ID=remote:dev:/home/jz"))
    #expect(rendered.contains("SUPACODE_TAB_ID=\(inv.tabID.uuidString.lowercased())"))
    #expect(rendered.contains("SUPACODE_SURFACE_ID=\(inv.surfaceID.uuidString.lowercased())"))
    #expect(rendered.contains("SUPACODE_SOCKET_PATH=/tmp/supacool-hook-xyz.sock"))
    #expect(rendered.contains("SUPACODE_WORKTREE_PATH=/home/jz/code/api"))
    #expect(rendered.contains("SUPACODE_ROOT_PATH=/home/jz/code/api"))
    #expect(rendered.contains("TMUX_SESSION=supacool-abc123"))
  }

  @Test func deferredInvocationPassesAliasUnquotedForSimpleNames() {
    let rendered = renderSSHInvocation(sampleInvocation())
    // The alias "dev" has only safe chars; remoteSpawnShellQuote leaves it bare.
    // `deferToSSHConfig` defaults true on the sample — so we expect the alias.
    #expect(rendered.contains(" dev "))
  }

  @Test func deferredInvocationOmitsConnectionFlags() {
    let rendered = renderSSHInvocation(
      sampleInvocation(
        user: "jz",
        hostname: "dev.example.com",
        port: 2222,
        identityFile: "~/.ssh/id_ed25519",
        deferToSSHConfig: true
      )
    )
    // Even with connection fields set, deferred mode ignores them.
    #expect(!rendered.contains("-p 2222"))
    #expect(!rendered.contains("-i "))
    #expect(!rendered.contains("jz@"))
    #expect(rendered.contains(" dev "))
  }

  @Test func explicitInvocationBuildsUserHostAndFlags() {
    let rendered = renderSSHInvocation(
      sampleInvocation(
        user: "jz",
        hostname: "dev.example.com",
        port: 2222,
        identityFile: "~/.ssh/id_ed25519",
        deferToSSHConfig: false
      )
    )
    #expect(rendered.contains("-p 2222"))
    // Identity file gets tilde-expanded; we won't hard-code HOME but
    // we can assert the raw `~/.ssh/…` form is gone.
    #expect(!rendered.contains(" ~/.ssh/id_ed25519"))
    #expect(rendered.contains("jz@dev.example.com"))
    // Alias is NOT appended when we build the target ourselves.
    #expect(!rendered.contains(" dev "))
  }

  @Test func explicitInvocationFallsBackToSSHAliasWhenHostnameMissing() {
    let rendered = renderSSHInvocation(
      sampleInvocation(
        user: "jz",
        hostname: nil,
        port: nil,
        identityFile: nil,
        deferToSSHConfig: false
      )
    )
    #expect(rendered.contains("jz@dev"))
    #expect(!rendered.contains("-p "))
    #expect(!rendered.contains("-i "))
  }

  @Test func explicitInvocationOmitsUserWhenEmpty() {
    let rendered = renderSSHInvocation(
      sampleInvocation(
        user: nil,
        hostname: "dev.example.com",
        port: nil,
        identityFile: nil,
        deferToSSHConfig: false
      )
    )
    // The target is just the hostname, no user@ prefix.
    #expect(rendered.contains(" dev.example.com "))
    #expect(!rendered.contains("@dev.example.com"))
  }

  @Test func invocationEndsWithBootstrapBashPipe() {
    let rendered = renderSSHInvocation(sampleInvocation())
    // The tail is the base64 bootstrap, wrapped in single quotes by
    // remoteSpawnShellQuote (contains spaces + pipe chars).
    #expect(rendered.contains("| base64 -d | bash -s --"))
  }

  @Test func invocationLowercasesUUIDs() {
    let inv = sampleInvocation(
      tabID: UUID(uuidString: "DEADBEEF-1234-1234-1234-123456789ABC")!,
      surfaceID: UUID(uuidString: "DEADBEEF-4321-4321-4321-CBA987654321")!
    )
    let rendered = renderSSHInvocation(inv)
    #expect(rendered.contains("SUPACODE_TAB_ID=deadbeef-1234-1234-1234-123456789abc"))
    #expect(rendered.contains("SUPACODE_SURFACE_ID=deadbeef-4321-4321-4321-cba987654321"))
  }

  // MARK: expandTilde

  @Test func expandTildeReplacesLeadingHome() {
    let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    #expect(expandTilde(in: "~/.ssh/id_ed25519") == "\(home)/.ssh/id_ed25519")
    #expect(expandTilde(in: "~") == home)
  }

  @Test func expandTildeLeavesRelativeAndAbsoluteUntouched() {
    #expect(expandTilde(in: "/etc/passwd") == "/etc/passwd")
    #expect(expandTilde(in: "relative/path") == "relative/path")
    #expect(expandTilde(in: "~otheruser/stuff") == "~otheruser/stuff")
  }

  private func sampleInvocation(
    user: String? = nil,
    hostname: String? = nil,
    port: Int? = nil,
    identityFile: String? = nil,
    deferToSSHConfig: Bool = true,
    tabID: UUID = UUID(),
    surfaceID: UUID = UUID(),
    agent: String? = "claude code"
  ) -> RemoteSpawnInvocation {
    RemoteSpawnInvocation(
      sshAlias: "dev",
      user: user,
      hostname: hostname,
      port: port,
      identityFile: identityFile,
      deferToSSHConfig: deferToSSHConfig,
      remoteWorkingDirectory: "/home/jz/code/api",
      remoteSocketPath: "/tmp/supacool-hook-xyz.sock",
      localSocketPath: "/tmp/supacool-local.sock",
      tmuxSessionName: "supacool-abc123",
      worktreeID: "remote:dev:/home/jz",
      tabID: tabID,
      surfaceID: surfaceID,
      agentCommand: agent,
      agent: nil
    )
  }
}
