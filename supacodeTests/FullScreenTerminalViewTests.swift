import Foundation
import IdentifiedCollections
import Testing

@testable import Supacool

@MainActor
struct FullScreenTerminalViewTests {
  @Test func matchedPullRequestReturnsBranchPRForWorktreeSession() {
    let worktree = Worktree(
      id: "/tmp/repo/.worktrees/feature-x",
      name: "feature-x",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/.worktrees/feature-x"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
    let repository = Repository(
      id: "/tmp/repo",
      rootURL: URL(fileURLWithPath: "/tmp/repo"),
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [worktree])
    )
    let session = AgentSession(
      repositoryID: "/tmp/repo",
      worktreeID: worktree.id,
      agent: .claude,
      initialPrompt: "Ship it"
    )
    let pullRequest = GithubPullRequest(
      number: 42,
      title: "Feature X",
      state: "OPEN",
      additions: 10,
      deletions: 2,
      isDraft: false,
      reviewDecision: nil,
      mergeable: nil,
      mergeStateStatus: nil,
      updatedAt: nil,
      url: "https://github.com/acme/repo/pull/42",
      headRefName: "feature-x",
      baseRefName: "main",
      commitsCount: nil,
      authorLogin: nil,
      statusCheckRollup: nil
    )

    let matched = FullScreenTerminalView.matchedPullRequest(
      session: session,
      repositories: IdentifiedArray(uniqueElements: [repository]),
      worktreeInfoByID: [
        worktree.id: WorktreeInfoEntry(
          addedLines: nil,
          removedLines: nil,
          pullRequest: pullRequest
        ),
      ]
    )

    #expect(matched == pullRequest)
  }

  @Test func finderRevealURLUsesCurrentWorkspacePathForLocalSession() {
    let path = "/Users/example/repo/.worktrees/feature-x"
    let session = AgentSession(
      repositoryID: "/Users/example/repo",
      worktreeID: "/Users/example/repo",
      currentWorkspacePath: path,
      agent: .claude,
      initialPrompt: "Ship it"
    )

    let url = FullScreenTerminalView.finderRevealURL(session: session)

    #expect(url?.path(percentEncoded: false) == path)
  }

  @Test func finderRevealURLIsNilForRemoteSessions() {
    let session = AgentSession(
      repositoryID: "/Users/example/repo",
      worktreeID: "remote:host:/home/dev/repo",
      currentWorkspacePath: "/home/dev/repo",
      agent: .claude,
      initialPrompt: "Ship it",
      remoteWorkspaceID: UUID()
    )

    #expect(FullScreenTerminalView.finderRevealURL(session: session) == nil)
  }

  @Test func matchedPullRequestIgnoresRepoRootSessions() {
    let repository = Repository(
      id: "/tmp/repo",
      rootURL: URL(fileURLWithPath: "/tmp/repo"),
      name: "repo",
      worktrees: []
    )
    let session = AgentSession(
      repositoryID: "/tmp/repo",
      worktreeID: "/tmp/repo",
      agent: .claude,
      initialPrompt: "Investigate"
    )
    let pullRequest = GithubPullRequest(
      number: 42,
      title: "Feature X",
      state: "OPEN",
      additions: 10,
      deletions: 2,
      isDraft: false,
      reviewDecision: nil,
      mergeable: nil,
      mergeStateStatus: nil,
      updatedAt: nil,
      url: "https://github.com/acme/repo/pull/42",
      headRefName: "feature-x",
      baseRefName: "main",
      commitsCount: nil,
      authorLogin: nil,
      statusCheckRollup: nil
    )

    let matched = FullScreenTerminalView.matchedPullRequest(
      session: session,
      repositories: IdentifiedArray(uniqueElements: [repository]),
      worktreeInfoByID: [
        session.worktreeID: WorktreeInfoEntry(
          addedLines: nil,
          removedLines: nil,
          pullRequest: pullRequest
        ),
      ]
    )

    #expect(matched == nil)
  }

  @Test func matchedPullRequestIgnoresMismatchedBranchPR() {
    let worktree = Worktree(
      id: "/tmp/repo/.worktrees/feature-x",
      name: "feature-x",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/.worktrees/feature-x"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
    let repository = Repository(
      id: "/tmp/repo",
      rootURL: URL(fileURLWithPath: "/tmp/repo"),
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [worktree])
    )
    let session = AgentSession(
      repositoryID: "/tmp/repo",
      worktreeID: worktree.id,
      agent: .claude,
      initialPrompt: "Ship it"
    )
    let pullRequest = GithubPullRequest(
      number: 43,
      title: "Other Branch",
      state: "OPEN",
      additions: 10,
      deletions: 2,
      isDraft: false,
      reviewDecision: nil,
      mergeable: nil,
      mergeStateStatus: nil,
      updatedAt: nil,
      url: "https://github.com/acme/repo/pull/43",
      headRefName: "different-branch",
      baseRefName: "main",
      commitsCount: nil,
      authorLogin: nil,
      statusCheckRollup: nil
    )

    let matched = FullScreenTerminalView.matchedPullRequest(
      session: session,
      repositories: IdentifiedArray(uniqueElements: [repository]),
      worktreeInfoByID: [
        worktree.id: WorktreeInfoEntry(
          addedLines: nil,
          removedLines: nil,
          pullRequest: pullRequest
        ),
      ]
    )

    #expect(matched == nil)
  }
}
