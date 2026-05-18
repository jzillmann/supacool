import Foundation
import Testing

@testable import Supacool

struct BoardLifecycleContextTests {
  @Test func repoRootSessionEmitsRepoRootMode() {
    // worktreeID == repositoryID is how a `.repoRoot` selection is
    // encoded once it reaches the AgentSession. The breadcrumb has to
    // surface that mode so a later trace audit can spot when the agent
    // is running inside the bare repo (and may have mutated its HEAD).
    let session = AgentSession(
      id: UUID(),
      repositoryID: "/tmp/repo",
      worktreeID: "/tmp/repo",
      agent: .claude,
      initialPrompt: "Fix CEN-6863"
    )
    let context = BoardFeature.lifecycleCreatedContext(for: session)
    #expect(context == "agent=claude;mode=repoRoot;cwd=/tmp/repo")
  }

  @Test func worktreeSessionEmitsWorktreeMode() {
    let session = AgentSession(
      id: UUID(),
      repositoryID: "/tmp/repo",
      worktreeID: "/tmp/repo-worktrees/fix-cen-6863",
      agent: .claude,
      initialPrompt: "Fix CEN-6863"
    )
    let context = BoardFeature.lifecycleCreatedContext(for: session)
    #expect(
      context == "agent=claude;mode=worktree;cwd=/tmp/repo-worktrees/fix-cen-6863"
    )
  }

  @Test func shellSessionRecordsShellAgent() {
    let session = AgentSession(
      id: UUID(),
      repositoryID: "/tmp/repo",
      worktreeID: "/tmp/repo",
      agent: nil,
      initialPrompt: ""
    )
    let context = BoardFeature.lifecycleCreatedContext(for: session)
    #expect(context == "agent=shell;mode=repoRoot;cwd=/tmp/repo")
  }

  @Test func remoteSessionIsFlaggedExplicitly() {
    let session = AgentSession(
      id: UUID(),
      repositoryID: "/tmp/repo",
      worktreeID: "/home/me/code",
      agent: .claude,
      initialPrompt: "Deploy",
      remoteWorkspaceID: UUID(),
      remoteHostID: UUID()
    )
    let context = BoardFeature.lifecycleCreatedContext(for: session)
    #expect(context == "agent=claude;mode=remote;cwd=/home/me/code")
  }
}
