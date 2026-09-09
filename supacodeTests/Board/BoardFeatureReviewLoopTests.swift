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
    #expect(input.contains("# Review handoff — copy this entire block"))
    #expect(input.contains("## Findings"))
    #expect(input.contains("SUPACOOL_REVIEW_RESULT_END"))
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

  @Test(.dependencies) func continueAfterBlockedRoutesFindingsToImplementer() async throws {
    let reviewerID = UUID()
    let report = reviewReport(
      verdict: "blocked",
      sha: "abc123",
      summary: "The frontend duplicates the backend resolver.",
      findings: ["Expose the backend-resolved dataset identity instead."]
    )
    let session = reviewLoopSession(
      loop: ReviewLoopState(
        reviewerTerminalID: reviewerID,
        phase: .needsDecision,
        round: 1,
        maximumRounds: 5,
        lastReviewedSHA: "abc123",
        lastSummary: "The frontend duplicates the backend resolver.",
        lastReport: report,
        escalationReason: "The frontend duplicates the backend resolver."
      )
    )
    let commands = LockIsolated<[TerminalClient.Command]>([])
    let store = reviewLoopStore(session: session, commands: commands)

    await store.send(.continueReviewLoop(id: session.id, additionalRounds: 1))
    await store.finish()

    let loop = try #require(store.state.sessions.first?.reviewLoop)
    #expect(loop.phase == .fixing)
    #expect(loop.round == 1)
    #expect(loop.maximumRounds == 6)
    guard case .sendPrompt(_, let tabID, let prompt) = try #require(commands.value.first) else {
      Issue.record("Expected the blocked findings to reach the implementation terminal")
      return
    }
    #expect(tabID.rawValue == session.primaryTerminalID)
    #expect(prompt.contains("Expose the backend-resolved dataset identity instead."))
  }

  @Test(.dependencies) func continueWithAMultiRoundGrantExtendsTheBudgetByThatMuch() async throws {
    let reviewerID = UUID()
    let session = reviewLoopSession(
      loop: ReviewLoopState(
        reviewerTerminalID: reviewerID,
        phase: .needsDecision,
        round: 5,
        maximumRounds: 5,
        lastReviewedSHA: "old-sha",
        lastSummary: "Round 5 still found changes."
      )
    )
    let commands = LockIsolated<[TerminalClient.Command]>([])
    let store = reviewLoopStore(session: session, commands: commands, headSHA: "new-sha")

    await store.send(
      .continueReviewLoop(
        id: session.id,
        additionalRounds: BoardFeature.reviewLoopMultiRoundGrant
      )
    )
    await store.receive(\._reviewLoopRereviewHeadResolved)
    await store.finish()

    let loop = try #require(store.state.sessions.first?.reviewLoop)
    #expect(loop.phase == .reviewing)
    #expect(loop.round == 6)
    // Round 6 of 8 — three more rounds before the loop must ask again.
    #expect(loop.maximumRounds == 8)
    guard case .sendPrompt(_, _, let prompt) = try #require(commands.value.first) else {
      Issue.record("Expected the re-review prompt to reach the reviewer")
      return
    }
    #expect(prompt.contains("round 6 of 8"))
  }

  @Test(.dependencies) func continueRefusesToRereviewAnUnchangedCommit() async throws {
    let reviewerID = UUID()
    let session = reviewLoopSession(
      loop: ReviewLoopState(
        reviewerTerminalID: reviewerID,
        phase: .needsDecision,
        round: 2,
        maximumRounds: 5,
        lastReviewedSHA: "same-sha",
        lastReport: "Codex stopped without a handoff block.",
        escalationReason: "Codex finished without a valid SUPACOOL_REVIEW_RESULT payload."
      )
    )
    let commands = LockIsolated<[TerminalClient.Command]>([])
    let store = reviewLoopStore(
      session: session,
      commands: commands,
      headSHA: "same-sha"
    )

    await store.send(.continueReviewLoop(id: session.id, additionalRounds: 1))
    await store.receive(\._reviewLoopRereviewHeadResolved)
    await store.finish()

    let loop = try #require(store.state.sessions.first?.reviewLoop)
    #expect(loop.phase == .needsDecision)
    #expect(loop.round == 2)
    #expect(loop.maximumRounds == 5)
    #expect(loop.escalationReason?.contains("Nothing was committed") == true)
    #expect(store.state.reviewLoopDecisionAlert?.hasPendingFindings == false)
    #expect(commands.value.isEmpty)
  }

  @Test(.dependencies) func continueRerunsTheReviewerOnceTheCommitMoved() async throws {
    let reviewerID = UUID()
    let session = reviewLoopSession(
      loop: ReviewLoopState(
        reviewerTerminalID: reviewerID,
        phase: .needsDecision,
        round: 2,
        maximumRounds: 5,
        lastReviewedSHA: "old-sha",
        lastSummary: "The handoff never parsed.",
        lastReport: "Codex stopped without a handoff block."
      )
    )
    let commands = LockIsolated<[TerminalClient.Command]>([])
    let store = reviewLoopStore(session: session, commands: commands, headSHA: "new-sha")

    await store.send(.continueReviewLoop(id: session.id, additionalRounds: 1))
    await store.receive(\._reviewLoopRereviewHeadResolved)
    await store.finish()

    let loop = try #require(store.state.sessions.first?.reviewLoop)
    #expect(loop.phase == .reviewing)
    #expect(loop.round == 3)
    #expect(loop.maximumRounds == 6)
    #expect(loop.expectedReviewSHA == "new-sha")
    guard case .sendPrompt(_, let tabID, let prompt) = try #require(commands.value.first) else {
      Issue.record("Expected the new commit to be sent to the reviewer")
      return
    }
    #expect(tabID.rawValue == reviewerID)
    #expect(prompt.contains("expected new-sha"))
    #expect(prompt.contains("round 3 of 6"))
  }

  @Test(.dependencies) func rereviewCarriesThePreviousRoundFindings() async throws {
    let reviewerID = UUID()
    let loop = ReviewLoopState(
      reviewerTerminalID: reviewerID,
      phase: .fixing,
      lastReviewedSHA: "old-sha",
      lastSummary: "One correctness issue remains.",
      lastReport: reviewReport(
        verdict: "changes",
        sha: "old-sha",
        summary: "One correctness issue remains.",
        findings: ["Handle an empty response before indexing."]
      )
    )
    let session = reviewLoopSession(loop: loop)
    let commands = LockIsolated<[TerminalClient.Command]>([])
    let store = reviewLoopStore(session: session, commands: commands)

    await store.send(
      ._reviewLoopImplementationHeadResolved(id: session.id, headSHA: "new-sha")
    )
    await store.finish()

    guard case .sendPrompt(_, _, let prompt) = try #require(commands.value.first) else {
      Issue.record("Expected the new commit to be sent to the reviewer")
      return
    }
    #expect(prompt.contains("Previous round findings"))
    #expect(prompt.contains("1. Handle an empty response before indexing."))
  }

  @Test(.dependencies) func reviewLoopInspectParksTheDecisionAndOpensTheReviewer() async throws {
    let reviewerID = UUID()
    let session = reviewLoopSession(
      loop: ReviewLoopState(
        reviewerTerminalID: reviewerID,
        phase: .needsDecision,
        round: 5,
        maximumRounds: 5,
        escalationReason: "The scope may be wrong."
      )
    )
    var state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }
    state.reviewLoopDecisionAlert = BoardFeature.ReviewLoopDecisionAlertState(
      sessionID: session.id,
      displayName: session.displayName,
      reason: "The scope may be wrong.",
      isArmed: true
    )
    let store = TestStore(initialState: state) {
      BoardFeature()
    } withDependencies: {
      $0.date = .constant(Date(timeIntervalSince1970: 1_750_000_000))
      $0.terminalClient.tabExists = { _, _ in true }
    }
    store.exhaustivity = .off

    await store.send(.openReviewLoopReviewer(id: session.id))

    #expect(store.state.reviewLoopDecisionAlert == nil)
    #expect(store.state.focusedSessionID == session.id)
    #expect(store.state.activeTerminalBySession[session.id] == reviewerID)
    #expect(store.state.sessions.first?.reviewLoop?.phase == .needsDecision)
    #expect(store.state.sessions.first?.reviewLoop?.escalationReason == "The scope may be wrong.")
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
  commands: LockIsolated<[TerminalClient.Command]> = LockIsolated<[TerminalClient.Command]>([]),
  headSHA: String? = nil
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
    $0[GitClientDependency.self].commitHistory = { _, _ in
      guard let headSHA else { return [] }
      return [
        GitCommitHistoryEntry(
          hash: headSHA,
          shortHash: String(headSHA.prefix(7)),
          date: Date(timeIntervalSince1970: 1_750_000_000),
          author: "Tester",
          subject: "Head"
        ),
      ]
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
