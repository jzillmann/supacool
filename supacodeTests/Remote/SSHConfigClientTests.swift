import Foundation
import Testing

@testable import Supacool

/// Covers the two pure parsers used by `SSHConfigClient` — we don't want
/// to shell out in tests. The live `ssh -G` invocation itself is too
/// environment-dependent to meaningfully unit-test; manual verification
/// on a real ssh_config handles that.
struct SSHConfigClientTests {

  // MARK: parseAliases

  @Test func parseAliasesSkipsWildcards() {
    let config = """
      Host *
        User default

      Host dev
        HostName dev.example.com

      Host prod bastion
        HostName prod.example.com
      """
    #expect(parseAliases(from: config) == ["dev", "prod", "bastion"])
  }

  @Test func parseAliasesIgnoresCommentsAndBlankLines() {
    let config = """
      # my hosts

      Host alpha
        HostName alpha.local

      # Host beta   <- commented out
      """
    #expect(parseAliases(from: config) == ["alpha"])
  }

  @Test func parseAliasesDeduplicates() {
    let config = """
      Host dup
        HostName one.example.com
      Host dup
        HostName two.example.com
      """
    #expect(parseAliases(from: config) == ["dup"])
  }

  @Test func parseAliasesSkipsNegationPatterns() {
    let config = """
      Host !internal
        User anon
      Host regular
        HostName regular.example.com
      """
    #expect(parseAliases(from: config) == ["regular"])
  }

  @Test func parseAliasesHandlesEmptyConfig() {
    #expect(parseAliases(from: "") == [])
    #expect(parseAliases(from: "# nothing but comments\n\n") == [])
  }

  @Test func parseAliasesIsCaseInsensitiveOnKeyword() {
    // `host` and `Host` are equivalent in OpenSSH.
    let config = """
      host lowercase
        HostName a.example.com
      HOST upcase
        HostName b.example.com
      """
    #expect(parseAliases(from: config) == ["lowercase", "upcase"])
  }

  // MARK: parseEffectiveConfig

  @Test func parseEffectiveConfigExtractsCoreFields() throws {
    // Trimmed representative sample of `ssh -G <alias>` output.
    let stdout = """
      user jz
      hostname dev.example.com
      port 2222
      identityfile /Users/jz/.ssh/id_ed25519
      identityfile /Users/jz/.ssh/id_rsa
      addressfamily any
      batchmode no
      """
    let parsed = try parseEffectiveConfig(alias: "dev", stdout: stdout)
    #expect(parsed.alias == "dev")
    #expect(parsed.hostname == "dev.example.com")
    #expect(parsed.user == "jz")
    #expect(parsed.port == 2222)
    #expect(parsed.identityFiles == [
      "/Users/jz/.ssh/id_ed25519",
      "/Users/jz/.ssh/id_rsa",
    ])
    #expect(parsed.hasComplexDirectives == false)
  }

  @Test func parseEffectiveConfigThrowsWithoutHostname() {
    let stdout = "user jz\nport 22\n"
    #expect(throws: (any Error).self) {
      try parseEffectiveConfig(alias: "broken", stdout: stdout)
    }
  }

  @Test func parseEffectiveConfigIgnoresNoiseLines() throws {
    let stdout = """

      hostname x.example.com
      # stray comment that ssh -G wouldn't emit but shouldn't crash us

      some-unknown-key value
      user
      """
    // `user ` with no value should be skipped (we guard on empty values).
    let parsed = try parseEffectiveConfig(alias: "x", stdout: stdout)
    #expect(parsed.hostname == "x.example.com")
    #expect(parsed.user == nil)
    #expect(parsed.port == nil)
    #expect(parsed.identityFiles.isEmpty)
    #expect(parsed.hasComplexDirectives == false)
  }

  @Test func parseEffectiveConfigFlagsProxyJump() throws {
    let stdout = """
      user jz
      hostname behind.bastion
      proxyjump bastion.example.com
      """
    let parsed = try parseEffectiveConfig(alias: "behind", stdout: stdout)
    #expect(parsed.hasComplexDirectives == true)
  }

  @Test func parseEffectiveConfigFlagsProxyCommand() throws {
    let stdout = """
      hostname x.example.com
      proxycommand ssh -W %h:%p bastion.example.com
      """
    let parsed = try parseEffectiveConfig(alias: "x", stdout: stdout)
    #expect(parsed.hasComplexDirectives == true)
  }

  @Test func parseEffectiveConfigIgnoresNoneForOptionalDirectives() throws {
    // `ssh -G` emits `proxyjump none` for unset directives — we must not
    // flag that as complex.
    let stdout = """
      hostname x.example.com
      proxyjump none
      proxycommand none
      certificatefile none
      """
    let parsed = try parseEffectiveConfig(alias: "x", stdout: stdout)
    #expect(parsed.hasComplexDirectives == false)
  }

  @Test func parseEffectiveConfigFlagsPercentTokensInHostname() throws {
    let stdout = """
      user jz
      hostname %h.internal
      """
    let parsed = try parseEffectiveConfig(alias: "x", stdout: stdout)
    #expect(parsed.hasComplexDirectives == true)
  }

  @Test func containsUnresolvedTokenHandlesEscapes() {
    #expect(containsUnresolvedToken("%h") == true)
    #expect(containsUnresolvedToken("literal-%%") == false)
    #expect(containsUnresolvedToken("plain.host") == false)
  }
}
