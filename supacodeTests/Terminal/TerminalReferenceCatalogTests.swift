import Foundation
import Testing

@testable import Supacool

@Suite("TerminalReferenceCatalog")
struct TerminalReferenceCatalogTests {
  private func session(_ references: [SessionReference]) -> AgentSession {
    AgentSession(
      repositoryID: "/tmp/repo",
      worktreeID: "/tmp/repo",
      agent: .claude,
      initialPrompt: "x",
      displayName: "x",
      references: references
    )
  }

  private static let passing = GithubPullRequestStatusCheck(name: "CI", status: "COMPLETED", conclusion: "SUCCESS")
  private static let failing = GithubPullRequestStatusCheck(name: "CI", status: "COMPLETED", conclusion: "FAILURE")

  @Test func prTonesFollowBallState() {
    let sessions = [
      session([
        .pullRequest(owner: "acme", repo: "rocket", number: 1, state: .open, title: nil),
        .pullRequest(owner: "acme", repo: "rocket", number: 2, state: .open, title: nil),
        .pullRequest(owner: "acme", repo: "rocket", number: 3, state: .merged, title: "Done"),
        // Open with no snapshot: state alone can't say green or red.
        .pullRequest(owner: "acme", repo: "rocket", number: 4, state: .open, title: nil),
      ]),
    ]
    let catalog = TerminalReferenceCatalog.build(
      sessions: sessions,
      referenceSnapshots: [
        "pr:acme/rocket#1": PullRequestSnapshot(
          state: .open, title: "Green", statusChecks: [Self.passing], reviewDecision: "APPROVED",
          mergeable: "MERGEABLE"
        ),
        "pr:acme/rocket#2": PullRequestSnapshot(state: .open, title: "Red", statusChecks: [Self.failing]),
      ],
      pulseSnapshots: [:],
      linearIssues: [:]
    )
    #expect(catalog.repositorySlugs == ["acme/rocket"])
    #expect(catalog.pullRequests["acme/rocket#1"]?.tone == .green)
    #expect(catalog.pullRequests["acme/rocket#1"]?.statusLabel == "Ready to merge")
    #expect(catalog.pullRequests["acme/rocket#2"]?.tone == .red)
    #expect(catalog.pullRequests["acme/rocket#3"]?.tone == .purple)
    #expect(catalog.pullRequests["acme/rocket#4"]?.tone == nil)
  }

  @Test func pulseSnapshotsContributeReposAndPRs() {
    let pullRequest = MonitoredPullRequest(
      number: 8, title: "Pulse PR", url: "https://github.com/acme/web/pull/8", author: "me", isDraft: true,
      headRefName: "b", updatedAt: Date(timeIntervalSince1970: 0), reviewDecision: nil, mergeable: nil,
      mergeStateStatus: nil, statusChecks: []
    )
    let catalog = TerminalReferenceCatalog.build(
      sessions: [],
      referenceSnapshots: [:],
      pulseSnapshots: [
        "repo": RepoPullRequestSnapshot(
          repositoryID: "repo", slug: "acme/web", pullRequests: [pullRequest],
          fetchedAt: Date(timeIntervalSince1970: 0)
        ),
      ],
      linearIssues: [:]
    )
    #expect(catalog.repositorySlugs == ["acme/web"])
    #expect(catalog.pullRequests["acme/web#8"]?.title == "Pulse PR")
  }

  @Test func ticketsCarryLinearStateAndColor() {
    let issue = LinearIssue(
      id: "uuid", identifier: "CEN-7", title: "Fix it", stateName: "In Review", stateType: "started",
      assignedToMe: false, stateColor: "#0F783C"
    )
    let catalog = TerminalReferenceCatalog.build(
      sessions: [], referenceSnapshots: [:], pulseSnapshots: [:], linearIssues: ["CEN-7": issue]
    )
    let ticket = catalog.tickets["CEN-7"]
    #expect(ticket?.stateName == "In Review")
    #expect(ticket?.colorHex == "#0f783c")
  }

  @Test func hoverLookupResolvesEveryLinkForm() {
    var catalog = TerminalReferenceCatalog()
    catalog.repositorySlugs = ["acme/rocket"]
    catalog.tickets["CEN-7"] = .init(identifier: "CEN-7")
    let pullRequest = TerminalReferenceCatalog.PullRequest(
      owner: "acme", repo: "rocket", number: 12, tone: .green, statusLabel: "Ready to merge"
    )
    catalog.pullRequests[pullRequest.key] = pullRequest

    #expect(catalog.entry(forLinkText: "CEN-7") == .ticket(.init(identifier: "CEN-7")))
    #expect(catalog.entry(forLinkText: "rocket#12") == .pullRequest(pullRequest))
    #expect(catalog.entry(forLinkText: "Acme/Rocket#12") == .pullRequest(pullRequest))
    #expect(catalog.entry(forLinkText: "https://github.com/acme/rocket/pull/12/files") == .pullRequest(pullRequest))
    #expect(catalog.entry(forLinkText: "rocket#13") == nil)
    #expect(catalog.entry(forLinkText: "https://example.com") == nil)
  }
}
