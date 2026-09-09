import ComposableArchitecture
import CryptoKit
import Foundation

private nonisolated let reviewLoopLogger = SupaLogger("Board.ReviewLoop")

extension BoardFeature {
  func reduceStartReviewLoop(
    state: inout State,
    id: AgentSession.ID,
    repositories: [Repository]
  ) -> Effect<Action> {
    guard let session = state.sessions.first(where: { $0.id == id }),
      session.reviewLoop == nil,
      session.agent != nil,
      !session.isRemote,
      let pullRequestURL = Self.actionablePullRequestURL(in: session),
      let repository = repositories.first(where: { $0.id == session.repositoryID })
    else { return .none }

    let primaryTabID = TerminalTabID(rawValue: session.primaryTerminalID)
    guard terminalClient.tabExists(session.worktreeID, primaryTabID) else {
      return escalateReviewLoop(
        state: &state,
        sessionID: id,
        reason: "Resume the implementation terminal before starting its review loop."
      )
    }

    let reviewerTerminalID = uuid()
    let now = date.now
    let prompt = Self.initialReviewerPrompt(
      pullRequestURL: pullRequestURL,
      round: 1,
      maximumRounds: Self.defaultReviewLoopMaximumRounds
    )
    let reviewer = SessionTerminal(
      id: reviewerTerminalID,
      role: .agent,
      agent: .codex,
      initialPrompt: prompt,
      displayName: "Reviewer",
      createdAt: now,
      lastActivityAt: now
    )
    state.$sessions.withLock { sessions in
      guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
      sessions[index].terminals.append(reviewer)
      sessions[index].reviewLoop = ReviewLoopState(
        reviewerTerminalID: reviewerTerminalID,
        pullRequestURL: pullRequestURL,
        maximumRounds: Self.defaultReviewLoopMaximumRounds,
        startedAt: now,
        updatedAt: now
      )
    }

    let worktree = Self.resumeWorktree(for: session, repository: repository)
    let command = AgentType.codex.command(
      prompt: prompt,
      bypassPermissions: Self.readBypassPermissions()
    )
    return .run { _ in
      await terminalClient.send(
        .createTabWithInput(
          worktree,
          input: command + "\r",
          runSetupScriptIfNew: false,
          id: reviewerTerminalID
        )
      )
    }
  }

  func reduceReviewLoopAgentTurnEnded(
    state: inout State,
    worktreeID: Worktree.ID,
    tabID: UUID,
    surfaceID: UUID,
    agent: String,
    message: String
  ) -> Effect<Action> {
    if let session = state.sessions.first(where: { session in
      guard session.worktreeID == worktreeID,
        let reviewerID = session.reviewLoop?.reviewerTerminalID
      else { return false }
      return tabID == reviewerID || surfaceID == reviewerID
    }), let loop = session.reviewLoop {
      guard agent.lowercased().contains("codex") else {
        reviewLoopLogger.warning("Ignoring non-Codex Stop from reviewer terminal \(tabID)")
        return .none
      }
      return reduceReviewerTurnEnded(
        state: &state,
        session: session,
        loop: loop,
        message: message
      )
    }

    guard
      let session = state.sessions.first(where: { session in
        guard session.worktreeID == worktreeID,
          session.reviewLoop?.phase == .fixing,
          tabID == session.primaryTerminalID
        else { return false }
        return !session.terminals.contains(where: {
          $0.hostTabID == tabID && $0.id == surfaceID
        })
      })
    else { return .none }

    let workspaceURL = URL(fileURLWithPath: session.currentWorkspacePath)
    return .run { [gitClient] send in
      let history = try? await gitClient.commitHistory(workspaceURL, 1)
      let headSHA = history?.first?.hash
      await send(._reviewLoopImplementationHeadResolved(id: session.id, headSHA: headSHA))
    }
  }

  func reduceReviewLoopImplementationHeadResolved(
    state: inout State,
    id: AgentSession.ID,
    headSHA: String?
  ) -> Effect<Action> {
    guard let session = state.sessions.first(where: { $0.id == id }),
      let loop = session.reviewLoop,
      loop.phase == .fixing,
      let reviewerTerminalID = loop.reviewerTerminalID
    else { return .none }

    guard let headSHA, !headSHA.isEmpty else {
      return escalateReviewLoop(
        state: &state,
        sessionID: id,
        reason: "The implementation turn ended, but Supacool could not resolve its current commit."
      )
    }
    guard headSHA != loop.lastReviewedSHA else {
      return escalateReviewLoop(
        state: &state,
        sessionID: id,
        reason: "The implementation turn ended without a new commit after review round \(loop.round). "
          + "The scope or architecture may need a decision."
      )
    }
    guard
      terminalClient.tabExists(
        session.worktreeID,
        TerminalTabID(rawValue: reviewerTerminalID)
      )
    else {
      return escalateReviewLoop(
        state: &state,
        sessionID: id,
        reason: "The reviewer terminal is no longer running."
      )
    }

    let nextRound = loop.round + 1
    let now = date.now
    state.$sessions.withLock { sessions in
      guard let index = sessions.firstIndex(where: { $0.id == id }),
        sessions[index].reviewLoop?.phase == .fixing
      else { return }
      sessions[index].reviewLoop?.phase = .reviewing
      sessions[index].reviewLoop?.round = nextRound
      sessions[index].reviewLoop?.expectedReviewSHA = headSHA
      sessions[index].reviewLoop?.escalationReason = nil
      sessions[index].reviewLoop?.convergenceWarning = nextRound >= Self.reviewLoopWarningRound
      sessions[index].reviewLoop?.updatedAt = now
    }
    let prompt = Self.rereviewPrompt(
      pullRequestURL: loop.pullRequestURL ?? "the current pull request",
      headSHA: headSHA,
      round: nextRound,
      maximumRounds: loop.maximumRounds,
      previousSummary: loop.lastSummary,
      previousFindings: loop.lastFindings
    )
    return .run { _ in
      await terminalClient.send(
        .sendPrompt(
          worktreeID: session.worktreeID,
          tabID: TerminalTabID(rawValue: reviewerTerminalID),
          text: prompt
        )
      )
    }
  }

  /// Opens the session full screen with the reviewer terminal active, and parks
  /// any pending decision instead of answering it.
  ///
  /// The loop stays in `.needsDecision`, so the orange review pill on the card and
  /// in the full-screen toolbar keeps offering the same choices. The user can read
  /// the diff and the reviewer output first, then decide from there.
  func reduceOpenReviewLoopReviewer(state: inout State, id: AgentSession.ID) -> Effect<Action> {
    guard let session = state.sessions.first(where: { $0.id == id }) else { return .none }
    state.reviewLoopDecisionAlert = nil
    state.focusedSessionID = id
    if let reviewerID = session.reviewLoop?.reviewerTerminalID {
      state.activeTerminalBySession[id] = reviewerID
    }
    return .none
  }

  func reduceDiagnoseReviewLoop(state: inout State, id: AgentSession.ID) -> Effect<Action> {
    guard let session = state.sessions.first(where: { $0.id == id }),
      let loop = session.reviewLoop,
      let reviewerID = loop.reviewerTerminalID
    else { return .none }
    guard terminalClient.tabExists(session.worktreeID, TerminalTabID(rawValue: reviewerID)) else {
      return escalateReviewLoop(
        state: &state,
        sessionID: id,
        reason: "The reviewer terminal is no longer running."
      )
    }
    let now = date.now
    state.reviewLoopDecisionAlert = nil
    state.$sessions.withLock { sessions in
      guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
      sessions[index].reviewLoop?.phase = .diagnosing
      sessions[index].reviewLoop?.updatedAt = now
    }
    let prompt = Self.diagnosisPrompt(loop: loop)
    return .run { _ in
      await terminalClient.send(
        .sendPrompt(
          worktreeID: session.worktreeID,
          tabID: TerminalTabID(rawValue: reviewerID),
          text: prompt
        )
      )
    }
  }

  /// The user answered a parked decision with "continue".
  ///
  /// When the reviewer left actionable findings behind — `changes` *or*
  /// `blocked` — continuing means handing those findings to the implementation
  /// agent. Only a decision with nothing left to fix (a parse failure, a stale
  /// report, an empty findings list) re-runs the reviewer, and even then the
  /// commit has to have moved first: re-reviewing an unchanged tree spends a
  /// round to reproduce the findings word for word.
  func reduceContinueReviewLoopOneRound(
    state: inout State,
    id: AgentSession.ID
  ) -> Effect<Action> {
    guard let session = state.sessions.first(where: { $0.id == id }),
      let loop = session.reviewLoop,
      loop.phase == .needsDecision
    else { return .none }

    let now = date.now
    state.reviewLoopDecisionAlert = nil

    if let report = loop.pendingFixReport {
      state.$sessions.withLock { sessions in
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].reviewLoop?.maximumRounds = Self.extendedMaximumRounds(for: loop)
        sessions[index].reviewLoop?.phase = .fixing
        sessions[index].reviewLoop?.escalationReason = nil
        sessions[index].reviewLoop?.updatedAt = now
      }
      return sendFixPrompt(state: &state, session: session, loop: loop, report: report)
    }

    guard let reviewerID = loop.reviewerTerminalID,
      terminalClient.tabExists(session.worktreeID, TerminalTabID(rawValue: reviewerID))
    else {
      return escalateReviewLoop(
        state: &state,
        sessionID: id,
        reason: "The reviewer terminal is no longer running."
      )
    }

    let workspaceURL = URL(fileURLWithPath: session.currentWorkspacePath)
    return .run { [gitClient] send in
      let history = try? await gitClient.commitHistory(workspaceURL, 1)
      await send(._reviewLoopRereviewHeadResolved(id: id, headSHA: history?.first?.hash))
    }
  }

  func reduceReviewLoopRereviewHeadResolved(
    state: inout State,
    id: AgentSession.ID,
    headSHA: String?
  ) -> Effect<Action> {
    guard let session = state.sessions.first(where: { $0.id == id }),
      let loop = session.reviewLoop,
      loop.phase == .needsDecision,
      let reviewerID = loop.reviewerTerminalID
    else { return .none }
    guard terminalClient.tabExists(session.worktreeID, TerminalTabID(rawValue: reviewerID)) else {
      return escalateReviewLoop(
        state: &state,
        sessionID: id,
        reason: "The reviewer terminal is no longer running."
      )
    }

    let resolvedHead = (headSHA?.isEmpty == false) ? headSHA : nil
    if let resolvedHead, resolvedHead == loop.lastReviewedSHA {
      return escalateReviewLoop(
        state: &state,
        sessionID: id,
        reason: "Nothing was committed since review round \(loop.round) — \(resolvedHead) is still "
          + "the head, so another review pass would only repeat itself. Open the reviewer, let the "
          + "agent commit a fix, diagnose the architecture, or stop."
      )
    }

    let now = date.now
    let extendedMaximum = Self.extendedMaximumRounds(for: loop)
    let nextRound = loop.round + 1
    state.$sessions.withLock { sessions in
      guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
      sessions[index].reviewLoop?.maximumRounds = extendedMaximum
      sessions[index].reviewLoop?.round = nextRound
      sessions[index].reviewLoop?.phase = .reviewing
      sessions[index].reviewLoop?.expectedReviewSHA = resolvedHead
      sessions[index].reviewLoop?.escalationReason = nil
      sessions[index].reviewLoop?.updatedAt = now
    }
    let prompt = Self.rereviewPrompt(
      pullRequestURL: loop.pullRequestURL ?? "the current pull request",
      headSHA: resolvedHead ?? loop.lastReviewedSHA ?? "current HEAD",
      round: nextRound,
      maximumRounds: extendedMaximum,
      previousSummary: loop.lastSummary,
      previousFindings: loop.lastFindings
    )
    return .run { _ in
      await terminalClient.send(
        .sendPrompt(
          worktreeID: session.worktreeID,
          tabID: TerminalTabID(rawValue: reviewerID),
          text: prompt
        )
      )
    }
  }

  func reduceStopReviewLoop(state: inout State, id: AgentSession.ID) -> Effect<Action> {
    let now = date.now
    state.reviewLoopDecisionAlert = nil
    state.$sessions.withLock { sessions in
      guard let index = sessions.firstIndex(where: { $0.id == id }),
        sessions[index].reviewLoop != nil
      else { return }
      sessions[index].reviewLoop?.phase = .stopped
      sessions[index].reviewLoop?.escalationReason = "Stopped by user."
      sessions[index].reviewLoop?.updatedAt = now
    }
    return .none
  }

  private func reduceReviewerTurnEnded(
    state: inout State,
    session: AgentSession,
    loop: ReviewLoopState,
    message: String
  ) -> Effect<Action> {
    if loop.phase == .diagnosing {
      let summary = Self.capped(message, limit: 2_000)
      updateReviewLoop(state: &state, sessionID: session.id) { updated in
        updated.phase = .needsDecision
        updated.lastSummary = summary
        updated.lastReport = Self.capped(message, limit: Self.maximumStoredReviewReportLength)
        updated.escalationReason = "The architecture diagnosis is ready for your decision."
      }
      return presentReviewLoopDecision(
        state: &state,
        sessionID: session.id,
        reason: "The architecture diagnosis is ready. Open the reviewer, change scope, continue one round, or stop."
      )
    }
    guard loop.phase == .reviewing else { return .none }
    guard let report = ReviewLoopReportParser.parse(message) else {
      updateReviewLoop(state: &state, sessionID: session.id) { updated in
        updated.lastReport = Self.capped(message, limit: Self.maximumStoredReviewReportLength)
      }
      return escalateReviewLoop(
        state: &state,
        sessionID: session.id,
        reason: "Codex finished without a valid SUPACOOL_REVIEW_RESULT payload. "
          + "Supacool paused rather than guessing."
      )
    }
    if let expectedSHA = loop.expectedReviewSHA, report.reviewedSHA != expectedSHA {
      return escalateReviewLoop(
        state: &state,
        sessionID: session.id,
        reason: "Codex reviewed commit \(report.reviewedSHA), but Supacool expected \(expectedSHA). "
          + "The loop paused to avoid applying stale findings."
      )
    }

    let fingerprint = Self.findingsFingerprint(report.findings)
    let repeatedCount =
      fingerprint == loop.lastFindingsFingerprint && !report.findings.isEmpty
      ? loop.repeatedFindingsCount + 1
      : 0
    let warning = loop.round >= Self.reviewLoopWarningRound || repeatedCount > 0
    updateReviewLoop(state: &state, sessionID: session.id) { updated in
      updated.expectedReviewSHA = nil
      updated.lastReviewedSHA = report.reviewedSHA
      updated.lastSummary = report.summary
      updated.lastReport = Self.capped(message, limit: Self.maximumStoredReviewReportLength)
      updated.lastFindingsFingerprint = fingerprint
      updated.repeatedFindingsCount = repeatedCount
      updated.convergenceWarning = warning
    }

    switch report.verdict {
    case .pass:
      updateReviewLoop(state: &state, sessionID: session.id) { updated in
        updated.phase = .passed
        updated.escalationReason = nil
      }
      return .none

    case .blocked:
      return escalateReviewLoop(
        state: &state,
        sessionID: session.id,
        reason: report.summary.isEmpty
          ? "The reviewer found an architectural or scope blocker."
          : report.summary
      )

    case .changes:
      guard loop.round < loop.maximumRounds else {
        return escalateReviewLoop(
          state: &state,
          sessionID: session.id,
          reason: "Round \(loop.round) still found changes after the configured "
            + "\(loop.maximumRounds)-round limit. The scope or architecture may be wrong."
        )
      }
      updateReviewLoop(state: &state, sessionID: session.id) { updated in
        updated.phase = .fixing
        updated.escalationReason = nil
      }
      return sendFixPrompt(state: &state, session: session, loop: loop, report: report)
    }
  }

  private func sendFixPrompt(
    state: inout State,
    session: AgentSession,
    loop: ReviewLoopState,
    report: ReviewLoopReport
  ) -> Effect<Action> {
    guard
      terminalClient.tabExists(
        session.worktreeID,
        TerminalTabID(rawValue: session.primaryTerminalID)
      )
    else {
      return escalateReviewLoop(
        state: &state,
        sessionID: session.id,
        reason: "The implementation terminal is no longer running."
      )
    }

    let prompt = Self.implementationPrompt(
      pullRequestURL: loop.pullRequestURL ?? "the current pull request",
      round: loop.round,
      report: report
    )
    return .run { _ in
      await terminalClient.send(
        .sendPrompt(
          worktreeID: session.worktreeID,
          tabID: TerminalTabID(rawValue: session.primaryTerminalID),
          text: prompt
        )
      )
    }
  }

  private func updateReviewLoop(
    state: inout State,
    sessionID: AgentSession.ID,
    update: (inout ReviewLoopState) -> Void
  ) {
    let now = date.now
    state.$sessions.withLock { sessions in
      guard let index = sessions.firstIndex(where: { $0.id == sessionID }),
        var loop = sessions[index].reviewLoop
      else { return }
      update(&loop)
      loop.updatedAt = now
      sessions[index].reviewLoop = loop
    }
  }

  private func escalateReviewLoop(
    state: inout State,
    sessionID: AgentSession.ID,
    reason: String
  ) -> Effect<Action> {
    updateReviewLoop(state: &state, sessionID: sessionID) { loop in
      loop.phase = .needsDecision
      loop.convergenceWarning = true
      loop.escalationReason = reason
    }
    return presentReviewLoopDecision(state: &state, sessionID: sessionID, reason: reason)
  }

  private func presentReviewLoopDecision(
    state: inout State,
    sessionID: AgentSession.ID,
    reason: String
  ) -> Effect<Action> {
    guard let session = state.sessions.first(where: { $0.id == sessionID }) else { return .none }
    state.reviewLoopDecisionAlert = ReviewLoopDecisionAlertState(
      sessionID: sessionID,
      displayName: session.displayName,
      reason: reason,
      isArmed: session.reviewLoop != nil,
      hasPendingFindings: session.reviewLoop?.pendingFixReport != nil
    )
    return .none
  }
}

extension BoardFeature {
  nonisolated static let defaultReviewLoopMaximumRounds = 5
  nonisolated static let reviewLoopWarningRound = 3
  nonisolated static let maximumStoredReviewReportLength = 12_000

  nonisolated static func actionablePullRequestURL(in session: AgentSession) -> String? {
    for reference in session.references {
      guard case .pullRequest(let owner, let repo, let number, let state, _) = reference,
        state == nil || state == .open || state == .draft
      else { continue }
      return "https://github.com/\(owner)/\(repo)/pull/\(number)"
    }
    return nil
  }

  nonisolated static func initialReviewerPrompt(
    pullRequestURL: String,
    round: Int,
    maximumRounds: Int
  ) -> String {
    reviewerPrompt(
      pullRequestURL: pullRequestURL,
      expectedSHA: "current pull-request HEAD",
      round: round,
      maximumRounds: maximumRounds,
      previousSummary: nil
    )
  }

  nonisolated static func rereviewPrompt(
    pullRequestURL: String,
    headSHA: String,
    round: Int,
    maximumRounds: Int,
    previousSummary: String?,
    previousFindings: [String] = []
  ) -> String {
    reviewerPrompt(
      pullRequestURL: pullRequestURL,
      expectedSHA: headSHA,
      round: round,
      maximumRounds: maximumRounds,
      previousSummary: previousSummary,
      previousFindings: previousFindings
    )
  }

  /// How far "continue one round" extends the budget: always at least one
  /// round beyond both the configured maximum and the round we are on.
  nonisolated static func extendedMaximumRounds(for loop: ReviewLoopState) -> Int {
    max(loop.maximumRounds + 1, loop.round + 1)
  }

  nonisolated static func reviewerPrompt(
    pullRequestURL: String,
    expectedSHA: String,
    round: Int,
    maximumRounds: Int,
    previousSummary: String?,
    previousFindings: [String] = []
  ) -> String {
    let prior =
      previousSummary.map {
        "\nPrevious round summary (verify it; do not repeat resolved points):\n\($0)\n"
      } ?? ""
    let priorFindings =
      previousFindings.isEmpty
      ? ""
      : "\nPrevious round findings — state for each one whether it is now resolved:\n"
        + previousFindings.enumerated().map { "\($0.offset + 1). \($0.element)" }
        .joined(separator: "\n") + "\n"
    return """
      Review \(pullRequestURL) as a strict, read-only code reviewer. This is round \(round) of \(maximumRounds).
      Review the exact current PR commit (expected \(expectedSHA)). Do not edit files, commit, push, or broaden scope.
      Focus on correctness, regressions, security, data loss, concurrency, and missing tests. Ignore style-only nits.
      If individual findings share a deeper architectural or scope problem, return blocked instead of inventing
      an endless stream of local fixes.
      \(prior)\(priorFindings)
      Your FINAL message must be this exact Markdown structure. It is a human-readable handoff, so keep every
      finding as one numbered list item and include both boundary markers:

      SUPACOOL_REVIEW_RESULT
      # Review handoff — copy this entire block

      Verdict: pass|changes|blocked
      Reviewed commit: `full git SHA`

      ## Summary

      Short summary.

      ## Findings

      1. Actionable finding with file and line references when useful.
      SUPACOOL_REVIEW_RESULT_END

      Use pass only when there are no actionable findings, changes when concrete fixes remain, and blocked when
      the architecture or requested scope needs a human decision. For pass, write `1. No findings.` under Findings.
      Do not put anything after SUPACOOL_REVIEW_RESULT_END.
      """
  }

  nonisolated static func implementationPrompt(
    pullRequestURL: String,
    round: Int,
    report: ReviewLoopReport
  ) -> String {
    let findings = report.findings.enumerated().map { index, finding in
      "\(index + 1). \(finding)"
    }.joined(separator: "\n")
    return """
      Review round \(round) for \(pullRequestURL) requested changes at \(report.reviewedSHA).
      Address every actionable finding below. Keep the fix within the ticket's intended scope, add or update tests,
      then commit and push the result. If a finding is invalid or exposes an architectural decision you cannot make,
      stop and explain that clearly instead of making speculative changes.

      Reviewer summary: \(report.summary)
      Findings:
      \(findings)
      """
  }

  nonisolated static func diagnosisPrompt(loop: ReviewLoopState) -> String {
    """
    Pause ordinary line-by-line review. Diagnose why this review loop is not converging after \(loop.round) rounds.
    Group repeated findings by common root cause and decide whether the architecture, scope boundary, or review
    standard is wrong. Recommend the smallest simplifying boundary or scope cut. Do not edit files. End with a
    concise decision memo for the user; this is one bounded diagnostic pass and must not start another review.

    Latest summary: \(loop.lastSummary ?? "Unavailable")
    Latest report: \(capped(loop.lastReport ?? "Unavailable", limit: 6_000))
    """
  }

  nonisolated static func findingsFingerprint(_ findings: [String]) -> String? {
    let normalized =
      findings
      .map { $0.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ") }
      .sorted()
      .joined(separator: "\n")
    guard !normalized.isEmpty else { return nil }
    let digest = SHA256.hash(data: Data(normalized.utf8))
    return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
  }

  nonisolated static func capped(_ value: String, limit: Int) -> String {
    String(value.prefix(limit))
  }
}
