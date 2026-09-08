import Foundation
import Testing

@testable import Supacool

@Suite("TerminalLinkRules")
struct TerminalLinkRulesTests {
  @Test func regexIsScopedToConfiguredTeamKeysAndStable() {
    let regex = TerminalLinkRules.ticketRegex(teamKeys: ["FOO", "CEN"])
    #expect(regex == #"\b(CEN|FOO)-\d+\b"#)
  }

  @Test func noRegexWithoutTeamKeys() {
    #expect(TerminalLinkRules.ticketRegex(teamKeys: []) == nil)
    #expect(TerminalLinkRules.configLines(teamKeys: []).isEmpty)
  }

  @Test func configLineMatchesGhosttyLinkSyntax() {
    let line = TerminalLinkRules.configLines(teamKeys: ["CEN"])
    #expect(line == "link = " + #"\b(CEN)-\d+\b"# + ",open,hover-mods:super\n")
  }

  @Test func teamKeysAreUppercasedDedupedAndFilteredForRegexSafety() {
    let keys = TerminalLinkRules.sanitizedTeamKeys(["cen", "CEN", " foo ", "BA D", "x|y", ""])
    #expect(keys == ["CEN", "FOO"])
  }

  @Test func matchedTicketResolvesToLinearWebURLWhenSlugIsConfigured() {
    let url = TerminalLinkRules.linearURL(
      forMatched: "CEN-9398",
      teamKeys: ["CEN"],
      linearOrgSlug: "centrum"
    )
    #expect(url?.absoluteString == "https://linear.app/centrum/issue/CEN-9398")
  }

  @Test func matchedTicketFallsBackToDesktopDeeplinkWithoutSlug() {
    let url = TerminalLinkRules.linearURL(
      forMatched: "CEN-9398",
      teamKeys: ["CEN"],
      linearOrgSlug: ""
    )
    #expect(url?.absoluteString == "linear://issue/CEN-9398")
  }

  @Test func unknownPrefixIsLeftToGhostty() {
    let url = TerminalLinkRules.linearURL(
      forMatched: "UTF-8",
      teamKeys: ["CEN"],
      linearOrgSlug: "centrum"
    )
    #expect(url == nil)
  }

  @Test func urlsAndPartialMatchesAreLeftToGhostty() {
    #expect(
      TerminalLinkRules.linearURL(
        forMatched: "https://example.com/CEN-1",
        teamKeys: ["CEN"],
        linearOrgSlug: "centrum"
      ) == nil
    )
    #expect(TerminalLinkRules.ticketID(in: "see CEN-1 please", teamKeys: ["CEN"]) == nil)
    #expect(TerminalLinkRules.ticketID(in: "cen-1", teamKeys: ["CEN"]) == nil)
  }

  @Test func teamKeysAreUnionedAcrossRepositories() {
    func repoSettings(teamKeys: String?) -> RepositorySettings {
      var settings = RepositorySettings.default
      settings.linearTeamKeys = teamKeys
      return settings
    }
    let settings = SettingsFile(
      repositories: [
        "/repos/a": repoSettings(teamKeys: "CEN, cen"),
        "/repos/b": repoSettings(teamKeys: "FOO"),
        "/repos/c": repoSettings(teamKeys: nil),
      ]
    )
    let keys = GhosttyRuntime.configuredLinearTeamKeys(in: settings)
    #expect(keys == ["CEN", "FOO"])
    #expect(TerminalLinkRules.ticketRegex(teamKeys: keys) == #"\b(CEN|FOO)-\d+\b"#)
  }

  @Test func surroundingWhitespaceIsTolerated() {
    let url = TerminalLinkRules.linearURL(
      forMatched: " CEN-42\n",
      teamKeys: ["CEN"],
      linearOrgSlug: ""
    )
    #expect(url?.absoluteString == "linear://issue/CEN-42")
  }
}
