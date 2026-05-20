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
  #endif
}
