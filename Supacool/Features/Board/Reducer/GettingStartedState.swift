import ComposableArchitecture
import Foundation

/// Session-level state for the first-launch Getting Started carousel.
/// Not persisted: `isPresented` is cleared on relaunch so the panel only
/// reappears if there are still incomplete, non-skipped tasks (the skip
/// set itself lives in `BoardFeature.State.skippedGettingStartedTasks`,
/// which *is* persisted via `@Shared(.appStorage(...))`).
@ObservableState
struct GettingStartedState: Equatable, Sendable {
  var isPresented: Bool = false
  var tasks: [GettingStartedTask] = []
  var currentIndex: Int = 0

  /// The task at `currentIndex`, clamped if `currentIndex` got out of
  /// sync with `tasks` (e.g. a task completed and we removed it).
  var currentTask: GettingStartedTask? {
    guard !tasks.isEmpty else { return nil }
    let idx = max(0, min(currentIndex, tasks.count - 1))
    return tasks[idx]
  }
}

/// Pure evaluation helper — given the three predicates and the persisted
/// skip set, returns the ordered list of tasks that belong in the
/// carousel. Extracted so `GettingStartedTests` can exercise the
/// bucketing without booting the rest of AppFeature.
nonisolated enum GettingStartedEvaluator {
  static func pending(
    hasRepositories: Bool,
    hasAllHooksInstalled: Bool,
    hasRemoteHosts: Bool,
    skipped: Set<String>
  ) -> [GettingStartedTask] {
    let candidates: [(GettingStartedTask, Bool)] = [
      (.setupRepo, !hasRepositories),
      (.installHooks, !hasAllHooksInstalled),
      (.setupRemoteHost, !hasRemoteHosts),
    ]
    return candidates
      .filter { _, incomplete in incomplete }
      .map(\.0)
      .filter { !skipped.contains($0.rawValue) }
  }
}
