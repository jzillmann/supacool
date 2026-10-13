import Foundation
import Testing

@testable import Supacool

@Suite("TerminalLinkRules")
struct TerminalLinkRulesTests {
  @Test func regexIsScopedToConfiguredTeamKeysAndStable() {
    let regex = TerminalLinkRules.ticketRegex(teamKeys: ["FOO", "CEN"])
    #expect(regex == #"\b(CEN|FOO)-\d+\b"#)
  }

  @Test func noTicketRegexWithoutTeamKeys() {
    #expect(TerminalLinkRules.ticketRegex(teamKeys: []) == nil)
    // Only the always-on `owner/repo#123` PR matcher remains.
    let lines = TerminalLinkRules.configLines(teamKeys: []).split(separator: "\n")
    #expect(lines.count == 1)
    #expect(lines.first?.contains("CEN") == false)
  }

  @Test func configLineMatchesGhosttyLinkSyntax() {
    let lines = TerminalLinkRules.configLines(teamKeys: ["CEN"]).split(separator: "\n")
    #expect(lines.first.map(String.init) == "link = " + #"\b(CEN)-\d+\b"# + ",open,hover-mods:super")
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

@Suite("TerminalLinkRules pull requests")
struct TerminalLinkRulesPullRequestTests {
  @Test func prRegexMatchesOwnerRepoAndKnownBareRepos() {
    let regex = TerminalLinkRules.pullRequestRegex(repositorySlugs: ["acme/rocket", "acme/web.app"])
    #expect(regex == #"(?<![\w./-])(?:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+|rocket|web\.app)#\d+\b"#)
    #expect(
      TerminalLinkRules.configLines(teamKeys: [], repositorySlugs: ["acme/rocket"])
        == "link = " + #"(?<![\w./-])(?:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+|rocket)#\d+\b"# + ",open,hover-mods:super\n"
    )
  }

  @Test func ownerRepoResolvesToGitHub() {
    let url = TerminalLinkRules.pullRequestURL(forMatched: "acme/rocket#42", repositorySlugs: [])
    #expect(url?.absoluteString == "https://github.com/acme/rocket/pull/42")
  }

  @Test func bareRepoResolvesOnlyWhenUnambiguous() {
    #expect(
      TerminalLinkRules.pullRequestURL(forMatched: "rocket#7\n", repositorySlugs: ["acme/rocket"])?
        .absoluteString == "https://github.com/acme/rocket/pull/7"
    )
    #expect(TerminalLinkRules.pullRequestURL(forMatched: "rocket#7", repositorySlugs: []) == nil)
    #expect(
      TerminalLinkRules.pullRequestURL(forMatched: "rocket#7", repositorySlugs: ["acme/rocket", "fork/rocket"])
        == nil
    )
    #expect(TerminalLinkRules.pullRequestURL(forMatched: "CEN-1", repositorySlugs: ["acme/rocket"]) == nil)
  }

  @Test func colorRulesGroupByColorAndRepo() {
    var catalog = TerminalReferenceCatalog()
    catalog.tickets["CEN-1"] = .init(identifier: "CEN-1", stateType: "started", stateColor: "#F2C94C")
    catalog.tickets["CEN-2"] = .init(identifier: "CEN-2", stateType: "started", stateColor: "#f2c94c")
    catalog.tickets["CEN-3"] = .init(identifier: "CEN-3", stateType: "completed")
    // Not started yet: left uncolored.
    catalog.tickets["CEN-4"] = .init(identifier: "CEN-4", stateType: "backlog", stateColor: "#bec2c8")
    catalog.pullRequests["acme/rocket#5"] = .init(
      owner: "acme", repo: "rocket", number: 5, tone: .green, statusLabel: "Ready to merge"
    )
    catalog.pullRequests["acme/rocket#9"] = .init(
      owner: "acme", repo: "rocket", number: 9, tone: .green, statusLabel: "Ready to merge"
    )
    // Unknown tone: no rule.
    catalog.pullRequests["acme/rocket#10"] = .init(
      owner: "acme", repo: "rocket", number: 10, tone: nil, statusLabel: "Open"
    )

    let lines = TerminalLinkRules.colorConfigLines(catalog: catalog) { tone in
      tone == .green ? "#00ff00" : "#990099"
    }
    #expect(
      lines == """
        link-color = \\b(?:CEN-(?:3))\\b,#990099
        link-color = \\b(?:CEN-(?:1|2))\\b,#f2c94c
        link-color = (?i)(?:(?:(?<![\\w./-])(?:acme/)?rocket#|github\\.com/acme/rocket/pull/)(?:5|9))\\b,#00ff00

        """
    )
  }

  @Test func colorRulesSplitToFitGhosttyLineLimit() {
    var catalog = TerminalReferenceCatalog()
    for index in 0..<400 {
      catalog.pullRequests["o/repo\(index)#1"] = .init(
        owner: "o", repo: "repo\(index)", number: 1, tone: .red, statusLabel: "CI failed"
      )
    }
    let lines = TerminalLinkRules.colorConfigLines(catalog: catalog) { _ in "#ff0000" }
      .split(separator: "\n")
    #expect(lines.count > 1)
    #expect(lines.allSatisfy { $0.utf8.count < 4096 })
  }
}
