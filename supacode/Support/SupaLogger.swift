import CustomDump
import OSLog

nonisolated struct SupaLogger: Sendable {
  private let category: String
  #if !DEBUG
    private let logger: Logger
  #endif

  init(_ category: String) {
    self.category = category
    #if !DEBUG
      self.logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: category)
    #endif
  }

  func debug(_ message: String) {
    #if DEBUG
      Self.dispatchPrint(category: category, message: message)
    #else
      logger.notice("\(message, privacy: .public)")
    #endif
  }

  func info(_ message: String) {
    #if DEBUG
      Self.dispatchPrint(category: category, message: message)
    #else
      logger.notice("\(message, privacy: .public)")
    #endif
  }

  func warning(_ message: String) {
    #if DEBUG
      Self.dispatchPrint(category: category, message: message)
    #else
      logger.warning("\(message, privacy: .public)")
    #endif
  }

  /// Sends the print to a dedicated serial background queue so the
  /// stdout `write()` syscall never blocks the calling thread. A live
  /// `sample` capture during a 1.56 s main-thread freeze showed
  /// `LogActionsReducer.reduce → SupaLogger.debug → print → _Stdout.write
  /// → __write_nocancel` accounting for 729 / 1191 main-thread samples
  /// — the stdout pipe to `make run-app`'s terminal had backed up and
  /// every TCA action was synchronously waiting on it. Background
  /// dispatch keeps the action log readable while removing the
  /// beachball.
  ///
  /// Trade-off: log lines may appear slightly out of order relative to
  /// each other if multiple threads write near-simultaneously; this is
  /// acceptable for developer debug output.
  #if DEBUG
    private static let printQueue = DispatchQueue(
      label: "io.morethan.supacool.SupaLogger-print",
      qos: .utility
    )

    fileprivate static func dispatchPrint(category: String, message: String) {
      printQueue.async {
        print("[\(category)] \(message)")
      }
    }

    /// Background-dispatch variant for raw multi-line text (e.g. the
    /// state diff that `LogActionsReducer` emits). Same rationale as
    /// the SupaLogger debug path; exposed so non-SupaLogger callers
    /// (LogActionsReducer prints CustomDump output directly) can
    /// participate in the same off-main pipeline.
    static func dispatchRawPrint(_ message: String) {
      printQueue.async {
        print(message)
      }
    }

    /// Off-main state diff for `LogActionsReducer`. Captures both
    /// snapshots by value, then runs the Equatable comparison and
    /// `CustomDump.diff` on the print queue rather than on the
    /// reducer's main-actor caller.
    ///
    /// A live `sample` capture during a 1.2 s freeze showed
    /// `LogActionsReducer.reduce` accounting for 137 main-thread
    /// samples per stall on a board with 19 sessions — the diff walk
    /// over the whole `AppFeature.State` (sessions, repositories,
    /// remoteHosts, etc.) is non-trivial and was being paid per
    /// action. Moving the comparison + diff off main eliminates that
    /// per-action tax.
    ///
    /// `State: Equatable` matches the constraint on `LogActionsReducer`.
    /// Wrapped in a `@unchecked Sendable` box because most TCA state
    /// types aren't formally `Sendable` even though they're
    /// effectively read-only after the reducer returns them.
    nonisolated static func dispatchStateDiff<State: Equatable>(
      previous: State,
      next: State,
    ) {
      let pair = StateDiffPair(previous: previous, next: next)
      printQueue.async {
        guard pair.previous != pair.next,
          let diff = CustomDump.diff(pair.previous, pair.next)
        else { return }
        print(diff)
      }
    }
  #endif
}

/// Generic snapshot wrapper used by `SupaLogger.dispatchStateDiff` to
/// ferry two `State` values to a background queue. `@unchecked
/// Sendable` because most TCA state types aren't formally `Sendable`
/// even though they're effectively read-only after the reducer hands
/// them back; we only ever read these copies from the diff worker.
/// Must be a top-level generic struct (Swift doesn't allow generic
/// types nested inside generic functions).
nonisolated private struct StateDiffPair<State>: @unchecked Sendable {
  let previous: State
  let next: State
}
