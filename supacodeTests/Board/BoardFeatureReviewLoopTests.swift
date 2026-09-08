import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import Supacool

@MainActor
extension BoardFeatureTests {
  @Test(.dependencies) func reviewLoopStartCreatesCollapsedCodexTerminal() async throws {
    let reviewerID = UUID(uuidString: "00000000-0000-0000-0000-000000000042")!
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let session = reviewLoopSession()
    let repository = reviewLoopRepository()
    let commands = LockIsolated<[TerminalClient.Command]>([])
    let state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }

    let store = TestStore(initialState: state) {
      BoardFeature()
    } withDependencies: {
      $0.uuid = .constant(reviewerID)
      $0.date = .constant(now)
      $0.terminalClient.tabExists = { _, _ in true }
      $0.terminalClient.send = { command in
        commands.withValue { $0.append(command) }
      }
    }
    store.exhaustivity = .off

    await store.send(.startReviewLoop(id: session.id, repositories: [repository]))
    await store.finish()

    let updated = try #require(store.state.sessions.first)
    #expect(updated.reviewLoop?.reviewerTerminalID == reviewerID)
    #expect(updated.reviewLoop?.phase == .reviewing)
    #expect(updated.reviewLoop?.round == 1)
    #expect(updated.terminals.last?.id == reviewerID)
    #expect(updated.terminals.last?.agent == .codex)
    guard case .createTabWithInput(_, let input, false, reviewerID) = try #require(commands.value.first)
    else {
      Issue.record("Expected a Codex reviewer tab command")
      return
    }
    #expect(input.contains("SUPACOOL_REVIEW_RESULT"))
    #expect(input.contains("round 1 of 5"))
  }

  @Test(.dependencies) func reviewLoopRoutesRequestedChangesToImplementer() async throws {
    let reviewerID = UUID()
    let session = reviewLoopSession(
      loop: ReviewLoopState(reviewerTerminalID: reviewerID)
    )
    let commands = LockIsolated<[TerminalClient.Command]>([])
    let store = reviewLoopStore(session: session, commands: commands)

    await store.send(
      .reviewLoopAgentTurnEnded(
        worktreeID: session.worktreeID,
        tabID: reviewerID,
        surfaceID: reviewerID,
        agent: "codex",
        message: reviewReport(
          verdict: "changes",
          sha: "abc123",
          summary: "One correctness issue remains.",
          findings: ["Handle an empty response before indexing."]
        )
      )
    )
    await store.finish()

    let loop = try #require(store.state.sessions.first?.reviewLoop)
    #expect(loop.phase == .fixing)
    #expect(loop.lastReviewedSHA == "abc123")
    guard case .sendPrompt(_, let tabID, let prompt) = try #require(commands.value.first) else {
      Issue.record("Expected findings to be sent to the implementation terminal")
      return
    }
    #expect(tabID.rawValue == session.primaryTerminalID)
    #expect(prompt.contains("Handle an empty response before indexing."))
  }

  @Test(.dependencies) func reviewLoopAdvancesOnlyAfterANewCommit() async throws {
    let reviewerID = UUID()
    let loop = ReviewLoopState(
      reviewerTerminalID: reviewerID,
      phase: .fixing,
      lastReviewedSHA: "old-sha"
    )
    let session = reviewLoopSession(loop: loop)
    let commands = LockIsolated<[TerminalClient.Command]>([])
    let store = reviewLoopStore(session: session, commands: commands)

    await store.send(
      ._reviewLoopImplementationHeadResolved(id: session.id, headSHA: "new-sha")
    )
    await store.finish()

    let updated = try #require(store.state.sessions.first?.reviewLoop)
    #expect(updated.phase == .reviewing)
    #expect(updated.round == 2)
    #expect(updated.expectedReviewSHA == "new-sha")
    guard case .sendPrompt(_, let tabID, let prompt) = try #require(commands.value.first) else {
      Issue.record("Expected the new commit to be sent to the reviewer")
      return
    }
    #expect(tabID.rawValue == reviewerID)
    #expect(prompt.contains("expected new-sha"))
  }

  @Test(.dependencies) func reviewLoopPausesOnStaleReviewOutput() async throws {
    let reviewerID = UUID()
    let session = reviewLoopSession(
      loop: ReviewLoopState(
        reviewerTerminalID: reviewerID,
        round: 2,
        expectedReviewSHA: "new-sha",
        lastReviewedSHA: "old-sha"
      )
    )
    let store = reviewLoopStore(session: session)

    await store.send(
      .reviewLoopAgentTurnEnded(
        worktreeID: session.worktreeID,
        tabID: reviewerID,
        surfaceID: reviewerID,
        agent: "codex",
        message: reviewReport(verdict: "pass", sha: "old-sha")
      )
    )

    let updated = try #require(store.state.sessions.first?.reviewLoop)
    #expect(updated.phase == .needsDecision)
    #expect(updated.escalationReason?.contains("stale findings") == true)
    #expect(store.state.reviewLoopDecisionAlert?.sessionID == session.id)
  }

  @Test(.dependencies) func reviewLoopHardStopsAtConfiguredRoundLimit() async throws {
    let reviewerID = UUID()
    let session = reviewLoopSession(
      loop: ReviewLoopState(
        reviewerTerminalID: reviewerID,
        round: 5,
        maximumRounds: 5,
        lastReviewedSHA: "previous-sha"
      )
    )
    let commands = LockIsolated<[TerminalClient.Command]>([])
    let store = reviewLoopStore(session: session, commands: commands)

    await store.send(
      .reviewLoopAgentTurnEnded(
        worktreeID: session.worktreeID,
        tabID: reviewerID,
        surfaceID: reviewerID,
        agent: "codex",
        message: reviewReport(
          verdict: "changes",
          sha: "current-sha",
          findings: ["The same architectural boundary still leaks."]
        )
      )
    )

    let updated = try #require(store.state.sessions.first?.reviewLoop)
    #expect(updated.phase == .needsDecision)
    #expect(updated.convergenceWarning)
    #expect(store.state.reviewLoopDecisionAlert != nil)
    #expect(commands.value.isEmpty)
  }

  @Test(.dependencies) func reviewLoopMatchesExactTerminalWhenSessionsShareAWorktree() async throws {
    let firstReviewerID = UUID()
    let secondReviewerID = UUID()
    let first = reviewLoopSession(
      id: UUID(),
      loop: ReviewLoopState(reviewerTerminalID: firstReviewerID)
    )
    let second = reviewLoopSession(
      id: UUID(),
      loop: ReviewLoopState(reviewerTerminalID: secondReviewerID)
    )
    let state = BoardFeature.State()
    state.$sessions.withLock { $0 = [first, second] }
    let store = TestStore(initialState: state) {
      BoardFeature()
    } withDependencies: {
      $0.date = .constant(Date(timeIntervalSince1970: 1_750_000_000))
    }
    store.exhaustivity = .off

    await store.send(
      .reviewLoopAgentTurnEnded(
        worktreeID: second.worktreeID,
        tabID: secondReviewerID,
        surfaceID: secondReviewerID,
        agent: "codex",
        message: reviewReport(verdict: "pass", sha: "second-sha")
      )
    )

    #expect(store.state.sessions[0].reviewLoop?.phase == .reviewing)
    #expect(store.state.sessions[0].reviewLoop?.lastReviewedSHA == nil)
    #expect(store.state.sessions[1].reviewLoop?.phase == .passed)
    #expect(store.state.sessions[1].reviewLoop?.lastReviewedSHA == "second-sha")
  }
}

@MainActor
private func reviewLoopStore(
  session: AgentSession,
  commands: LockIsolated<[TerminalClient.Command]> = LockIsolated<[TerminalClient.Command]>([])
) -> TestStoreOf<BoardFeature> {
  let state = BoardFeature.State()
  state.$sessions.withLock { $0 = [session] }
  let store = TestStore(initialState: state) {
    BoardFeature()
  } withDependencies: {
    $0.date = .constant(Date(timeIntervalSince1970: 1_750_000_000))
    $0.terminalClient.tabExists = { _, _ in true }
    $0.terminalClient.send = { command in
      commands.withValue { $0.append(command) }
    }
  }
  store.exhaustivity = .off
  return store
}

private func reviewLoopSession(id: UUID = UUID(), loop: ReviewLoopState? = nil) -> AgentSession {
  AgentSession(
    id: id,
    repositoryID: "/tmp/repo",
    worktreeID: "/tmp/repo",
    agent: .claude,
    initialPrompt: "Fix the ticket",
    displayName: "Fix the ticket",
    reviewLoop: loop,
    references: [
      .pullRequest(owner: "acme", repo: "widgets", number: 42, state: .open, title: "Fix")
    ]
  )
}

private func reviewLoopRepository() -> Repository {
  Repository(
    id: "/tmp/repo",
    rootURL: URL(fileURLWithPath: "/tmp/repo"),
    name: "repo",
    worktrees: []
  )
}

private func reviewReport(
  verdict: String,
  sha: String,
  summary: String = "Review complete.",
  findings: [String] = []
) -> String {
  let encodedFindings = findings.map { "\"\($0)\"" }.joined(separator: ",")
  return """
    SUPACOOL_REVIEW_RESULT
    {"verdict":"\(verdict)","reviewed_sha":"\(sha)","summary":"\(summary)","findings":[\(encodedFindings)]}
    """
}
