import ComposableArchitecture
import Foundation

/// Session → board-status derivation, extracted from `BoardRootView` so the
/// board UI and the remote-control MCP tools classify identically — a session
/// must never look different to a remote agent than it does on screen.
///
/// Inputs are plain snapshots of board/repositories state; construct one
/// per read, don't cache it.
@MainActor
struct BoardSessionClassifier {
  let terminalManager: WorktreeTerminalManager
  let prReferenceSnapshots: [String: PullRequestSnapshot]
  let reinitializingSessionIDs: Set<AgentSession.ID>
  let repositories: IdentifiedArrayOf<Repository>
  let worktreeInfoByID: [Worktree.ID: WorktreeInfoEntry]

  /// Classifier reads live busy state from WorktreeTerminalManager and the
  /// persisted last-known-busy flag on the session.
  ///
  /// Tab doesn't exist anymore:
  /// - `lastKnownBusy=true`: the agent was working when the app went away
  ///   (crash / quit mid-turn). Card reads as .interrupted (yellow warning).
  /// - `lastKnownBusy=false`: the agent was idle. Card reads as .detached
  ///   (moon icon, gray). Safe and expected after a normal relaunch.
  ///
  /// Tab exists:
  /// - Busy → .inProgress.
  /// - Not busy, inside the 3s grace period after creation → .fresh so
  ///   cards don't immediately flip to Waiting while claude/codex is
  ///   starting up.
  /// - Not busy, past grace or has completed at least once → .waitingOnMe.
  func classify(_ session: AgentSession) -> BoardSessionStatus {
    let tabID = TerminalTabID(rawValue: session.id)
    let tabExists = terminalManager.sessionTabExists(
      worktreeID: session.worktreeID,
      tabID: tabID
    )
    let status = BoardSessionStatus.classify(
      session: session,
      tabExists: tabExists,
      activity: terminalManager.agentActivity(worktreeID: session.worktreeID, tabID: tabID),
      waitingExternally: waitingExternally(for: session)
    )
    if !tabExists, reinitializingSessionIDs.contains(session.id) {
      return .inProgress
    }
    return status
  }

  /// Whether the session sits in "Waiting on External". Prefer the per-session
  /// PR snapshots (the explicit `pr:#number` link that also drives the card's
  /// reason chip) so bucket and chip never disagree; fall back to the
  /// branch-matched PR only when no snapshot has been fetched yet.
  func waitingExternally(for session: AgentSession) -> Bool {
    let states = prReferenceSnapshots.ballStates(of: session)
    if !states.isEmpty {
      return PRBallState.sessionWaitsExternally(states)
    }
    return BoardPullRequestChecks.isWaitingExternal(matchedPullRequest(for: session))
  }

  func matchedPullRequest(for session: AgentSession) -> GithubPullRequest? {
    guard let repo = repositories[id: session.repositoryID] else { return nil }
    let rootPath = repo.rootURL.standardizedFileURL.path(percentEncoded: false)
    let workspacePath = session.currentWorkspacePath
    guard workspacePath != rootPath else { return nil }
    guard let worktree = repo.worktrees.first(where: { $0.id == workspacePath }) else {
      return nil
    }
    guard let pullRequest = worktreeInfoByID[workspacePath]?.pullRequest else { return nil }
    guard pullRequest.headRefName == nil || pullRequest.headRefName == worktree.name else {
      return nil
    }
    return pullRequest
  }
}
