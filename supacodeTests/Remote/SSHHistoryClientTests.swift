import Foundation
import Testing

@testable import Supacool

/// Unit tests for the pure parsing pieces of `SSHHistoryClient`. The
/// live file IO is a thin wrapper; we only cover the tokenizer, the
/// per-line parser, the zsh timestamp prefix handling, and the rollup.
struct SSHHistoryClientTests {

  // MARK: shellTokens

  @Test func shellTokensSplitsOnWhitespace() {
    #expect(shellTokens(from: "ssh jz@jack.local") == ["ssh", "jz@jack.local"])
  }

  @Test func shellTokensRespectsQuotes() {
    #expect(
      shellTokens(from: #"ssh -o "User=j z" jack"#)
        == ["ssh", "-o", "User=j z", "jack"]
    )
    #expect(
      shellTokens(from: "ssh -o 'Port=2222' jack")
        == ["ssh", "-o", "Port=2222", "jack"]
    )
  }

  @Test func shellTokensHonorsBackslashEscapes() {
    #expect(
      shellTokens(from: #"ssh j\ z@host"#)
        == ["ssh", "j z@host"]
    )
  }

  @Test func shellTokensCollapsesRuns() {
    #expect(
      shellTokens(from: "   ssh    jack    ")
        == ["ssh", "jack"]
    )
  }

  // MARK: stripZshExtendedPrefix

  @Test func stripZshExtendedPrefixExtractsTimestamp() {
    let (cmd, date) = stripZshExtendedPrefix(": 1703512345:0;ssh jack.local")
    #expect(cmd == "ssh jack.local")
    #expect(date == Date(timeIntervalSince1970: 1_703_512_345))
  }

  @Test func stripZshExtendedPrefixLeavesBareLinesAlone() {
    let (cmd, date) = stripZshExtendedPrefix("ssh jack.local")
    #expect(cmd == "ssh jack.local")
    #expect(date == nil)
  }

  @Test func stripZshExtendedPrefixHandlesMissingSemicolon() {
    // Corrupted line — no semicolon means we fall through to a bare parse.
    let (cmd, date) = stripZshExtendedPrefix(": 1703512345:0 ssh jack.local")
    #expect(cmd == ": 1703512345:0 ssh jack.local")
    #expect(date == nil)
  }

  // MARK: parseSSHCommand

  @Test func parseSSHCommandExtractsUserAndHost() throws {
    let obs = try #require(parseSSHCommand("ssh jz@jack.local", timestamp: nil))
    #expect(obs.user == "jz")
    #expect(obs.hostname == "jack.local")
    #expect(obs.port == nil)
    #expect(obs.identityFile == nil)
  }

  @Test func parseSSHCommandExtractsHostWithoutUser() throws {
    let obs = try #require(parseSSHCommand("ssh jack.local", timestamp: nil))
    #expect(obs.user == nil)
    #expect(obs.hostname == "jack.local")
  }

  @Test func parseSSHCommandExtractsPortAndIdentity() throws {
    let obs = try #require(
      parseSSHCommand(
        "ssh -p 2222 -i ~/.ssh/id_foo jz@jack.local",
        timestamp: nil
      )
    )
    #expect(obs.user == "jz")
    #expect(obs.hostname == "jack.local")
    #expect(obs.port == 2222)
    #expect(obs.identityFile == "~/.ssh/id_foo")
  }

  @Test func parseSSHCommandExtractsLFlagUser() throws {
    let obs = try #require(
      parseSSHCommand("ssh -l jz -p 2222 jack.local", timestamp: nil)
    )
    #expect(obs.user == "jz")
    #expect(obs.port == 2222)
  }

  @Test func parseSSHCommandExtractsOFlagOptions() throws {
    let obs = try #require(
      parseSSHCommand(
        #"ssh -o "User=jz" -o Port=2222 -o IdentityFile=~/.ssh/id_bar jack.local"#,
        timestamp: nil
      )
    )
    #expect(obs.user == "jz")
    #expect(obs.port == 2222)
    #expect(obs.identityFile == "~/.ssh/id_bar")
  }

  @Test func parseSSHCommandHonorsEndOfOptionsSeparator() throws {
    let obs = try #require(
      parseSSHCommand("ssh -v -- jz@jack.local", timestamp: nil)
    )
    #expect(obs.user == "jz")
    #expect(obs.hostname == "jack.local")
  }

  @Test func parseSSHCommandSkipsFlagsTakingArguments() throws {
    // -L takes an argument; we should skip it and land on the destination.
    let obs = try #require(
      parseSSHCommand("ssh -L 8080:localhost:80 jz@jack.local", timestamp: nil)
    )
    #expect(obs.user == "jz")
    #expect(obs.hostname == "jack.local")
  }

  @Test func parseSSHCommandHandlesAbsolutePathToSSH() throws {
    let obs = try #require(
      parseSSHCommand("/usr/bin/ssh jack.local", timestamp: nil)
    )
    #expect(obs.hostname == "jack.local")
  }

  @Test func parseSSHCommandSkipsInlineEnvAssignments() throws {
    let obs = try #require(
      parseSSHCommand("TERM=xterm-256color ssh jz@jack.local", timestamp: nil)
    )
    #expect(obs.user == "jz")
    #expect(obs.hostname == "jack.local")
  }

  @Test func parseSSHCommandSkipsWrappers() throws {
    let obs = try #require(
      parseSSHCommand("time ssh jz@jack.local", timestamp: nil)
    )
    #expect(obs.user == "jz")
  }

  @Test func parseSSHCommandRejectsSudo() {
    // Sudo would change the acting user — don't guess; drop the line.
    #expect(parseSSHCommand("sudo ssh jz@jack.local", timestamp: nil) == nil)
  }

  @Test func parseSSHCommandRejectsShellSubstitutionDestinations() {
    #expect(parseSSHCommand("ssh $HOST", timestamp: nil) == nil)
    #expect(parseSSHCommand("ssh /not/a/host", timestamp: nil) == nil)
  }

  @Test func parseSSHCommandRejectsNonSSHLines() {
    #expect(parseSSHCommand("git commit -m \"ssh worked\"", timestamp: nil) == nil)
    #expect(parseSSHCommand("echo 'ssh jack.local'", timestamp: nil) == nil)
  }

  @Test func parseSSHCommandRejectsLinesWithoutDestination() {
    #expect(parseSSHCommand("ssh", timestamp: nil) == nil)
    #expect(parseSSHCommand("ssh -v", timestamp: nil) == nil)
  }

  // MARK: rollUp

  @Test func rollUpDedupesIdenticalTargets() {
    let obs = [
      RawObservation(
        raw: "ssh jack",
        user: nil,
        hostname: "jack",
        port: nil,
        identityFile: nil,
        timestamp: Date(timeIntervalSince1970: 1000)
      ),
      RawObservation(
        raw: "ssh jack",
        user: nil,
        hostname: "jack",
        port: nil,
        identityFile: nil,
        timestamp: Date(timeIntervalSince1970: 2000)
      ),
    ]
    let rolled = rollUp(observations: obs)
    #expect(rolled.count == 1)
    #expect(rolled.first?.timesSeen == 2)
    #expect(rolled.first?.lastSeenAt == Date(timeIntervalSince1970: 2000))
  }

  @Test func rollUpSeparatesDistinctIdentityFiles() {
    let obs = [
      RawObservation(
        raw: "ssh -i ~/id1 jack",
        user: "jz",
        hostname: "jack",
        port: nil,
        identityFile: "~/id1",
        timestamp: nil
      ),
      RawObservation(
        raw: "ssh -i ~/id2 jack",
        user: "jz",
        hostname: "jack",
        port: nil,
        identityFile: "~/id2",
        timestamp: nil
      ),
    ]
    let rolled = rollUp(observations: obs)
    #expect(rolled.count == 2)
  }

  @Test func rollUpSortsMostRecentFirst() {
    let obs = [
      RawObservation(
        raw: "ssh a",
        user: nil,
        hostname: "a",
        port: nil,
        identityFile: nil,
        timestamp: Date(timeIntervalSince1970: 1000)
      ),
      RawObservation(
        raw: "ssh b",
        user: nil,
        hostname: "b",
        port: nil,
        identityFile: nil,
        timestamp: Date(timeIntervalSince1970: 3000)
      ),
      RawObservation(
        raw: "ssh c",
        user: nil,
        hostname: "c",
        port: nil,
        identityFile: nil,
        timestamp: Date(timeIntervalSince1970: 2000)
      ),
    ]
    let rolled = rollUp(observations: obs)
    #expect(rolled.map(\.hostname) == ["b", "c", "a"])
  }

  // MARK: parseZshHistory + parseBashHistory end-to-end

  @Test func parseZshHistoryCoversMixedContent() {
    let contents = """
      : 1703512345:0;ssh jz@jack.local
      : 1703512400:0;ls /tmp
      : 1703512500:0;ssh -p 2222 devbox
      : 1703512600:0;ssh jz@jack.local
      """
    let observed = parseZshHistory(contents)
    #expect(observed.count == 3)
    #expect(observed[0].hostname == "jack.local")
    #expect(observed[1].hostname == "devbox")
    #expect(observed[1].port == 2222)
  }

  @Test func parseBashHistoryIgnoresTimestampCommentLines() {
    let contents = """
      #1703512345
      ssh jz@jack.local
      ls
      ssh devbox
      """
    let observed = parseBashHistory(contents)
    #expect(observed.count == 2)
    #expect(observed[0].hostname == "jack.local")
    #expect(observed[1].hostname == "devbox")
  }
}
