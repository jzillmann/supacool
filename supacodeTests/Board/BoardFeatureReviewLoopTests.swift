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
    #expect(store.state.pendingReviewDecisions.map(\.id) == [session.id])
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
    #expect(store.state.pendingReviewDecisions.map(\.id) == [session.id])
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
    #expect(
      loop.decisionChoices == [
        .rereview(additionalRounds: 1),
        .rereview(additionalRounds: BoardFeature.reviewLoopMultiRoundGrant),
      ]
    )
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
    let state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }
    let store = TestStore(initialState: state) {
      BoardFeature()
    } withDependencies: {
      $0.date = .constant(Date(timeIntervalSince1970: 1_750_000_000))
      $0.terminalClient.tabExists = { _, _ in true }
    }
    store.exhaustivity = .off

    await store.send(.openReviewLoopReviewer(id: session.id))

    // Inspecting parks the decision: its card stays in the stack.
    #expect(store.state.pendingReviewDecisions.map(\.id) == [session.id])
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

  @Test(.dependencies) func quietFixTurnsKeepWaitingUntilTheLimit() async throws {
    let session = reviewLoopSession(
      loop: ReviewLoopState(
        reviewerTerminalID: UUID(),
        phase: .fixing,
        round: 1,
        lastReviewedSHA: "same-sha",
        lastReport: reviewReport(verdict: "changes", sha: "same-sha", findings: ["Fix the race."])
      )
    )
    let commands = LockIsolated<[TerminalClient.Command]>([])
    let store = reviewLoopStore(session: session, commands: commands)

    // An agent that ends a turn while its tests or push still run is not stuck.
    for quietTurn in 1..<BoardFeature.reviewLoopCommitlessTurnLimit {
      await store.send(._reviewLoopImplementationHeadResolved(id: session.id, headSHA: "same-sha"))
      let loop = try #require(store.state.sessions.first?.reviewLoop)
      #expect(loop.phase == .fixing)
      #expect(loop.commitlessTurnCount == quietTurn)
      #expect(store.state.pendingReviewDecisions.isEmpty)
    }

    await store.send(._reviewLoopImplementationHeadResolved(id: session.id, headSHA: "same-sha"))

    let loop = try #require(store.state.sessions.first?.reviewLoop)
    #expect(loop.phase == .needsDecision)
    #expect(loop.pausedDuringFix)
    #expect(loop.decisionChoices == [.resumeRound])
    #expect(store.state.pendingReviewDecisions.map(\.id) == [session.id])
    #expect(commands.value.isEmpty)
  }

  @Test(.dependencies) func implementationTurnEndKeepsTheAgentMessage() async throws {
    let session = reviewLoopSession(
      loop: ReviewLoopState(
        reviewerTerminalID: UUID(),
        phase: .fixing,
        lastReviewedSHA: "old-sha"
      )
    )
    let store = reviewLoopStore(session: session, headSHA: "old-sha")

    await store.send(
      .reviewLoopAgentTurnEnded(
        worktreeID: session.worktreeID,
        tabID: session.primaryTerminalID,
        surfaceID: UUID(),
        agent: "claude",
        message: "Verification is running; I commit and push once it is green."
      )
    )
    await store.receive(\._reviewLoopImplementationHeadResolved)

    let loop = try #require(store.state.sessions.first?.reviewLoop)
    #expect(loop.phase == .fixing)
    #expect(loop.lastAgentMessage == "Verification is running; I commit and push once it is green.")
    #expect(loop.commitlessTurnCount == 1)
  }

  @Test(.dependencies) func anUnpushedLocalCommitIsNotReviewedYet() async throws {
    let reviewerID = UUID()
    let session = reviewLoopSession(
      loop: ReviewLoopState(
        reviewerTerminalID: reviewerID,
        phase: .fixing,
        lastReviewedSHA: "old-sha"
      )
    )
    let commands = LockIsolated<[TerminalClient.Command]>([])
    let publishedSHA = LockIsolated<String?>("old-sha")
    let store = reviewLoopStore(
      session: session,
      commands: commands,
      headSHA: "local-sha",
      publishedSHA: publishedSHA
    )
    let turnEnded = BoardFeature.Action.reviewLoopAgentTurnEnded(
      worktreeID: session.worktreeID,
      tabID: session.primaryTerminalID,
      surfaceID: UUID(),
      agent: "claude",
      message: "Committed; pushing now."
    )

    await store.send(turnEnded)
    await store.receive(\._reviewLoopImplementationHeadResolved)
    #expect(store.state.sessions.first?.reviewLoop?.phase == .fixing)
    #expect(commands.value.isEmpty)

    publishedSHA.withValue { $0 = "pushed-sha" }
    await store.send(turnEnded)
    await store.receive(\._reviewLoopImplementationHeadResolved)
    await store.finish()

    let loop = try #require(store.state.sessions.first?.reviewLoop)
    #expect(loop.phase == .reviewing)
    #expect(loop.expectedReviewSHA == "pushed-sha")
    #expect(loop.commitlessTurnCount == 0)
    guard case .sendPrompt(_, let tabID, let prompt) = try #require(commands.value.first) else {
      Issue.record("Expected the pushed commit to be sent to the reviewer")
      return
    }
    #expect(tabID.rawValue == reviewerID)
    #expect(prompt.contains("expected pushed-sha"))
  }

  @Test(.dependencies) func continueOnAPausedRoundNeverResendsTheFindings() async throws {
    let session = reviewLoopSession(
      loop: ReviewLoopState(
        reviewerTerminalID: UUID(),
        phase: .needsDecision,
        round: 1,
        lastReviewedSHA: "same-sha",
        lastReport: reviewReport(verdict: "blocked", sha: "same-sha", findings: ["Decide the boundary."]),
        pausedDuringFix: true
      )
    )
    let commands = LockIsolated<[TerminalClient.Command]>([])
    let store = reviewLoopStore(session: session, commands: commands, headSHA: "same-sha")

    await store.send(.continueReviewLoop(id: session.id, additionalRounds: 1))
    await store.receive(\._reviewLoopResumeHeadResolved)
    await store.finish()

    let loop = try #require(store.state.sessions.first?.reviewLoop)
    #expect(loop.phase == .fixing)
    #expect(loop.maximumRounds == 5)
    guard case .sendPrompt(_, _, let prompt) = try #require(commands.value.first) else {
      Issue.record("Expected a nudge to the implementation terminal")
      return
    }
    #expect(prompt.contains("still open"))
    #expect(!prompt.contains("Decide the boundary."))
  }

  @Test(.dependencies) func blockedFindingsAskTheAgentForOptionsNotCode() async throws {
    let session = reviewLoopSession(
      loop: ReviewLoopState(
        reviewerTerminalID: UUID(),
        phase: .needsDecision,
        lastReviewedSHA: "abc123",
        lastReport: reviewReport(verdict: "blocked", sha: "abc123", findings: ["Pick a recovery region."])
      )
    )
    let commands = LockIsolated<[TerminalClient.Command]>([])
    let store = reviewLoopStore(session: session, commands: commands)

    await store.send(.continueReviewLoop(id: session.id, additionalRounds: 1))
    await store.finish()

    guard case .sendPrompt(_, _, let prompt) = try #require(commands.value.first) else {
      Issue.record("Expected the blocked findings to reach the implementation terminal")
      return
    }
    #expect(prompt.contains("is blocked at abc123"))
    #expect(prompt.contains("wait for the answer"))
    #expect(prompt.contains("Pick a recovery region."))
  }

  @Test(.dependencies) func inspectingAPausedRoundOpensTheAgentTerminal() async throws {
    let session = reviewLoopSession(
      loop: ReviewLoopState(reviewerTerminalID: UUID(), phase: .needsDecision, pausedDuringFix: true)
    )
    let store = reviewLoopStore(session: session)

    await store.send(.openReviewLoopReviewer(id: session.id))

    #expect(store.state.activeTerminalBySession[session.id] == session.primaryTerminalID)
    #expect(store.state.sessions.first?.reviewLoop?.phase == .needsDecision)
  }

  @Test(.dependencies) func continueRoundNudgesTheAgentWhenNothingWasCommitted() async throws {
    let reviewerID = UUID()
    let session = reviewLoopSession(
      loop: ReviewLoopState(
        reviewerTerminalID: reviewerID,
        phase: .needsDecision,
        round: 2,
        maximumRounds: 5,
        lastReviewedSHA: "same-sha",
        escalationReason: "The implementation turn ended without a new commit after review round 2.",
        pausedDuringFix: true
      )
    )
    let commands = LockIsolated<[TerminalClient.Command]>([])
    let store = reviewLoopStore(session: session, commands: commands, headSHA: "same-sha")

    await store.send(.resumeReviewLoopRound(id: session.id))
    await store.receive(\._reviewLoopResumeHeadResolved)
    await store.finish()

    let loop = try #require(store.state.sessions.first?.reviewLoop)
    #expect(loop.phase == .fixing)
    // The round stays open: no new round is spent and the limit is untouched.
    #expect(loop.round == 2)
    #expect(loop.maximumRounds == 5)
    #expect(!loop.pausedDuringFix)
    #expect(loop.escalationReason == nil)
    #expect(store.state.pendingReviewDecisions.isEmpty)
    guard case .sendPrompt(_, let tabID, let prompt) = try #require(commands.value.first) else {
      Issue.record("Expected a nudge to the implementation terminal")
      return
    }
    #expect(tabID.rawValue == session.primaryTerminalID)
    #expect(prompt.contains("Review round 2"))
    #expect(prompt.contains("still open"))
  }

  @Test(.dependencies) func continueRoundReviewsACommitThatLandedMeanwhile() async throws {
    let reviewerID = UUID()
    let session = reviewLoopSession(
      loop: ReviewLoopState(
        reviewerTerminalID: reviewerID,
        phase: .needsDecision,
        round: 2,
        maximumRounds: 5,
        lastReviewedSHA: "old-sha",
        pausedDuringFix: true
      )
    )
    let commands = LockIsolated<[TerminalClient.Command]>([])
    let store = reviewLoopStore(session: session, commands: commands, headSHA: "new-sha")

    await store.send(.resumeReviewLoopRound(id: session.id))
    await store.receive(\._reviewLoopResumeHeadResolved)
    await store.finish()

    let loop = try #require(store.state.sessions.first?.reviewLoop)
    #expect(loop.phase == .reviewing)
    #expect(loop.round == 3)
    #expect(loop.expectedReviewSHA == "new-sha")
    guard case .sendPrompt(_, let tabID, let prompt) = try #require(commands.value.first) else {
      Issue.record("Expected the new commit to be sent to the reviewer")
      return
    }
    #expect(tabID.rawValue == reviewerID)
    #expect(prompt.contains("expected new-sha"))
  }

  @Test(.dependencies) func laterHidesADecisionUntilTheLoopAsksAgain() async throws {
    let session = reviewLoopSession(
      loop: ReviewLoopState(
        reviewerTerminalID: UUID(),
        phase: .fixing,
        lastReviewedSHA: "same-sha"
      )
    )
    let store = reviewLoopStore(session: session, headSHA: "same-sha")
    let limit = BoardFeature.reviewLoopCommitlessTurnLimit

    for _ in 0..<limit {
      await store.send(._reviewLoopImplementationHeadResolved(id: session.id, headSHA: "same-sha"))
    }
    #expect(store.state.pendingReviewDecisions.map(\.id) == [session.id])

    await store.send(.snoozeReviewDecision(id: session.id))
    #expect(store.state.pendingReviewDecisions.isEmpty)
    #expect(store.state.sessions.first?.reviewLoop?.phase == .needsDecision)

    // Resume, then the quiet-turn limit again: a fresh escalation shows again.
    await store.send(.resumeReviewLoopRound(id: session.id))
    await store.receive(\._reviewLoopResumeHeadResolved)
    for _ in 0..<limit {
      await store.send(._reviewLoopImplementationHeadResolved(id: session.id, headSHA: "same-sha"))
    }
    #expect(store.state.pendingReviewDecisions.map(\.id) == [session.id])
  }

  @Test(.dependencies) func reviewLoopThatCannotStartBecomesATrayNotice() async throws {
    let session = reviewLoopSession()
    let state = BoardFeature.State()
    state.$sessions.withLock { $0 = [session] }
    let store = TestStore(initialState: state) {
      BoardFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 1_750_000_000))
      $0.terminalClient.tabExists = { _, _ in false }
    }
    store.exhaustivity = .off

    await store.send(.startReviewLoop(id: session.id, repositories: [reviewLoopRepository()]))

    #expect(store.state.sessions.first?.reviewLoop == nil)
    #expect(store.state.pendingReviewDecisions.isEmpty)
    guard case .reviewLoopUnavailable(let sessionID, _, let message)? = store.state.trayCards.first?.kind
    else {
      Issue.record("Expected a reviewLoopUnavailable tray card")
      return
    }
    #expect(sessionID == session.id)
    #expect(message.contains("Resume the implementation terminal"))
  }

  @Test func reviewLoopStateDecodesOlderSnapshotsWithoutPausedDuringFix() throws {
    let json = #"{"phase":"needsDecision","round":2,"maximumRounds":5}"#
    let loop = try JSONDecoder().decode(ReviewLoopState.self, from: Data(json.utf8))
    #expect(loop.phase == .needsDecision)
    #expect(!loop.pausedDuringFix)
  }

  @Test(.dependencies) func askReviewerSendsTheAgentPushbackToTheReviewer() async throws {
    let reviewerID = UUID()
    let session = reviewLoopSession(
      loop: ReviewLoopState(
        reviewerTerminalID: reviewerID,
        phase: .needsDecision,
        round: 2,
        maximumRounds: 5,
        lastReviewedSHA: "abc123",
        lastReport: reviewReport(
          verdict: "changes",
          sha: "abc123",
          findings: ["Guard against an empty response."]
        ),
        escalationReason: "The agent ended 3 turns in a row without pushing a new commit after review round 2.",
        pausedDuringFix: true,
        commitlessTurnCount: 3,
        lastAgentMessage: "The response can never be empty here: the upstream validator rejects it. "
          + "Is finding 1 still needed?"
      )
    )
    let commands = LockIsolated<[TerminalClient.Command]>([])
    let store = reviewLoopStore(session: session, commands: commands)
    let loopBefore = try #require(session.reviewLoop)
    #expect(loopBefore.decisionChoices == [.resumeRound, .askReviewer])

    await store.send(.askReviewLoopReviewer(id: session.id))
    await store.finish()

    let loop = try #require(store.state.sessions.first?.reviewLoop)
    #expect(loop.phase == .conferring)
    #expect(loop.round == 2)
    #expect(!loop.pausedDuringFix)
    #expect(loop.commitlessTurnCount == 0)
    #expect(store.state.pendingReviewDecisions.isEmpty)
    guard case .sendPrompt(_, let tabID, let prompt) = try #require(commands.value.first) else {
      Issue.record("Expected the agent's message to reach the reviewer terminal")
      return
    }
    #expect(tabID.rawValue == reviewerID)
    #expect(prompt.contains("upstream validator rejects it"))
    #expect(prompt.contains("1. Guard against an empty response."))
    #expect(prompt.contains("SUPACOOL_REVIEW_RESULT_END"))
  }

  @Test(.dependencies) func askReviewerIsAvailableMidRoundWithoutParking() async throws {
    let reviewerID = UUID()
    let session = reviewLoopSession(
      loop: ReviewLoopState(
        reviewerTerminalID: reviewerID,
        phase: .fixing,
        round: 1,
        lastReviewedSHA: "abc123",
        commitlessTurnCount: 1,
        lastAgentMessage: "Which of the two resolvers should own the dataset id?"
      )
    )
    let commands = LockIsolated<[TerminalClient.Command]>([])
    let store = reviewLoopStore(session: session, commands: commands)
    #expect(session.reviewLoop?.canAskReviewer == true)

    await store.send(.askReviewLoopReviewer(id: session.id))
    await store.finish()

    #expect(store.state.sessions.first?.reviewLoop?.phase == .conferring)
    guard case .sendPrompt(_, let tabID, let prompt) = try #require(commands.value.first) else {
      Issue.record("Expected the question to reach the reviewer terminal")
      return
    }
    #expect(tabID.rawValue == reviewerID)
    #expect(prompt.contains("Which of the two resolvers"))
  }

  @Test(.dependencies) func reviewerAnswerWithStandingFindingsGoesBackToTheAgentInTheSameRound() async throws {
    let reviewerID = UUID()
    let session = reviewLoopSession(
      loop: ReviewLoopState(
        reviewerTerminalID: reviewerID,
        phase: .conferring,
        round: 2,
        maximumRounds: 5,
        lastReviewedSHA: "abc123",
        lastAgentMessage: "Is finding 1 still needed?"
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
          sha: "abc123",
          summary: "Finding 1 stands: the validator runs only on the write path.",
          findings: ["Guard the read path against an empty response."]
        )
      )
    )
    await store.finish()

    let loop = try #require(store.state.sessions.first?.reviewLoop)
    #expect(loop.phase == .fixing)
    #expect(loop.round == 2)
    #expect(loop.lastAgentMessage == nil)
    #expect(loop.lastSummary == "Finding 1 stands: the validator runs only on the write path.")
    guard case .sendPrompt(_, let tabID, let prompt) = try #require(commands.value.first) else {
      Issue.record("Expected the reviewer's answer to reach the implementation terminal")
      return
    }
    #expect(tabID.rawValue == session.primaryTerminalID)
    #expect(prompt.contains("Round 2 is still open"))
    #expect(prompt.contains("validator runs only on the write path"))
    #expect(prompt.contains("1. Guard the read path against an empty response."))
  }

  @Test(.dependencies) func reviewerWithdrawingEveryFindingPassesTheLoop() async throws {
    let reviewerID = UUID()
    let session = reviewLoopSession(
      loop: ReviewLoopState(
        reviewerTerminalID: reviewerID,
        phase: .conferring,
        round: 2,
        lastReviewedSHA: "abc123"
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
        message: reviewReport(verdict: "pass", sha: "abc123", summary: "Agreed, the validator covers it.")
      )
    )

    #expect(store.state.sessions.first?.reviewLoop?.phase == .passed)
    #expect(commands.value.isEmpty)
  }

  @Test(.dependencies) func reviewerAnswerThatIsBlockedParksForTheUser() async throws {
    let reviewerID = UUID()
    let session = reviewLoopSession(
      loop: ReviewLoopState(
        reviewerTerminalID: reviewerID,
        phase: .conferring,
        round: 2,
        lastReviewedSHA: "abc123"
      )
    )
    let store = reviewLoopStore(session: session)

    await store.send(
      .reviewLoopAgentTurnEnded(
        worktreeID: session.worktreeID,
        tabID: reviewerID,
        surfaceID: reviewerID,
        agent: "codex",
        message: reviewReport(
          verdict: "blocked",
          sha: "abc123",
          summary: "We disagree on who owns the resolver; the user must decide.",
          findings: ["Pick one owner for dataset resolution."]
        )
      )
    )

    let loop = try #require(store.state.sessions.first?.reviewLoop)
    #expect(loop.phase == .needsDecision)
    #expect(!loop.pausedDuringFix)
    #expect(loop.escalationReason?.contains("user must decide") == true)
    #expect(store.state.pendingReviewDecisions.map(\.id) == [session.id])
  }

}

@MainActor
private func reviewLoopStore(
  session: AgentSession,
  commands: LockIsolated<[TerminalClient.Command]> = LockIsolated<[TerminalClient.Command]>([]),
  headSHA: String? = nil,
  publishedSHA: LockIsolated<String?> = LockIsolated<String?>(nil)
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
    $0[GitClientDependency.self].publishedHeadSHA = { _ in publishedSHA.value }
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
