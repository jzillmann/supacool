import Foundation
import Testing

@testable import Supacool

@Suite struct SessionRecoveryStoreTests {
  private func makeSession(
    worktree: String,
    displayName: String? = nil
  ) -> AgentSession {
    AgentSession(
      repositoryID: "/repo",
      worktreeID: worktree,
      agent: nil,
      initialPrompt: "work",
      displayName: displayName
    )
  }

  // The core guarantee behind the 2026-06-04 session-loss fix: when a save
  // drops sessions vs the previously persisted set, those sessions are
  // recorded to the recovery store so launch self-heal can re-adopt them.
  @Test func recordsSessionsDroppedBetweenWrites() {
    let storage = SettingsFileStorage.inMemory()
    let keep = makeSession(worktree: "/wt/keep")
    let dropped = makeSession(worktree: "/wt/dropped")

    let recorded = SessionRecoveryStore.recordRemovals(
      previous: [keep, dropped],
      next: [keep],
      storage: storage
    )

    #expect(recorded.map(\.id) == [dropped.id])
    let snapshots = SessionRecoveryStore.loadSnapshots(storage: storage)
    #expect(snapshots.count == 1)
    #expect(snapshots.first?.sessions.map(\.id) == [dropped.id])
  }

  @Test func noSnapshotWhenNothingRemoved() {
    let storage = SettingsFileStorage.inMemory()
    let first = makeSession(worktree: "/wt/a")
    let second = makeSession(worktree: "/wt/b")

    // Same set, and a superset (a session added) — neither drops anything.
    SessionRecoveryStore.recordRemovals(previous: [first], next: [first], storage: storage)
    SessionRecoveryStore.recordRemovals(previous: [first], next: [first, second], storage: storage)

    #expect(SessionRecoveryStore.loadSnapshots(storage: storage).isEmpty)
  }

  @Test func boundsSnapshotCountToMax() {
    let storage = SettingsFileStorage.inMemory()
    let survivor = makeSession(worktree: "/wt/survivor")

    // Each call drops a distinct session, appending one snapshot.
    for index in 0..<(SessionRecoveryStore.maxSnapshots + 10) {
      let dropped = makeSession(worktree: "/wt/dropped-\(index)")
      SessionRecoveryStore.recordRemovals(
        previous: [survivor, dropped],
        next: [survivor],
        storage: storage
      )
    }

    let snapshots = SessionRecoveryStore.loadSnapshots(storage: storage)
    #expect(snapshots.count == SessionRecoveryStore.maxSnapshots)
    // The cap drops the oldest, so the newest removal must survive.
    #expect(snapshots.last?.sessions.first?.worktreeID == "/wt/dropped-\(SessionRecoveryStore.maxSnapshots + 9)")
  }
}
