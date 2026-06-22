import Dependencies
import Foundation
import OSLog
import Sharing

/// `@Shared(.agentSessions)` — the list of Supacool board sessions, persisted
/// to JSON alongside supacode's other settings files.
///
/// `Sharing` dedupes the in-memory `@Shared` box by this `id`, so the bound
/// sessions directory is part of it on purpose. Production always resolves the
/// single `~/.supacool/sessions`, so the whole app shares ONE box (unchanged).
/// Under test each `@Test` gets a unique temp directory (injected via
/// `sessionStorageLocations`), so each resolves a DISTINCT box. Without the
/// directory here, every concurrently-running Swift Testing `@Test` shares one
/// global box and pollutes the others — the flaky board/bookmark/PR-pulse
/// failures that only surfaced under CI's timing. (`-parallel-testing-enabled
/// NO` disables XCTest's multi-process parallelism, NOT Swift Testing's
/// in-process concurrency, so the box is genuinely contended across tests.)
nonisolated struct AgentSessionsKeyID: Hashable, Sendable {
  var directory: URL
}

/// On-disk locations the board's per-session store reads and writes. Injected
/// as a dependency so tests run against an isolated temp directory instead of
/// the real `~/.supacool`. Without this seam every test sharing
/// `@Shared(.agentSessions)` reads and writes the *same* real directory, so
/// sessions written by one test leak into the next (and persist across runs) —
/// the cross-test pollution that turned the board/bookmark/PR-pulse suites red.
/// Mirrors how `settingsFileStorage` swaps to an in-memory store under test.
nonisolated struct SessionStorageLocations: Sendable {
  /// `<root>/sessions` — one folder per session. See `SessionDirectoryStore`.
  var directory: URL
}

nonisolated enum SessionStorageLocationsKey: DependencyKey {
  static var liveValue: SessionStorageLocations {
    SessionStorageLocations(directory: SupacoolPaths.sessionsDirectory)
  }
  static var previewValue: SessionStorageLocations { liveValue }
  /// A fresh, empty temp root per dependency context. The `.dependencies`
  /// test trait resets the context per test, so each test resolves a new
  /// unique directory — isolating both load (starts empty) and save.
  static var testValue: SessionStorageLocations {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "supacool-sessions-\(UUID().uuidString)", directoryHint: .isDirectory)
    return SessionStorageLocations(
      directory: root.appending(path: "sessions", directoryHint: .isDirectory)
    )
  }
}

extension DependencyValues {
  nonisolated var sessionStorageLocations: SessionStorageLocations {
    get { self[SessionStorageLocationsKey.self] }
    set { self[SessionStorageLocationsKey.self] = newValue }
  }
}

nonisolated struct AgentSessionsKey: SharedKey {
  private static let logger = SupaLogger("AgentSessions")
  /// Diagnostic logger that goes through unified logging in **all** build
  /// configurations (Debug uses `os.Logger` here vs SupaLogger's print).
  /// Lets us inspect the save-rate telemetry via `log stream / log show`
  /// regardless of how the app was launched.
  private static let telemetryLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "io.morethan.supacool",
    category: "AgentSessions.SaveTelemetry"
  )

  /// Serial queue used for the JSON encode + atomic-write half of `save`.
  /// `Sharing` invokes `save` synchronously from `withLock`'s defer; with
  /// many agent sessions the encode (~96 KB pretty-printed JSON) and the
  /// disk write together cost tens of ms on every reducer mutation — a
  /// hot main-thread block visible as steady-state beachballs. Sharing's
  /// `SaveContinuation` is designed for async fulfilment, so we resolve
  /// the `SettingsFileStorage` dependency on the calling thread, hop to
  /// this queue for the heavy work, and resume the continuation when the
  /// write finishes.
  private static let saveQueue = DispatchQueue(
    label: "io.morethan.supacool.agent-sessions-save",
    qos: .utility
  )

  /// Diagnostic counter used to measure how often `save` is invoked vs
  /// how often the encoded payload actually changes. Sharing fires save
  /// from `withLock`'s defer regardless of whether the body mutated, so
  /// `submissions` ≫ `payloadChanges` indicates the underlying churn,
  /// while `encodes` is what actually hit JSONEncoder after coalescing.
  /// Emits a log line every 5 s; cheap to leave in until we've ruled out
  /// remaining churn.
  private actor SaveTelemetry {
    private var submissions = 0
    private var encodes = 0
    private var payloadChanges = 0
    private var lastReportedAt = Date()
    private var lastPayloadHash: Int?

    func recordSubmission() {
      submissions += 1
    }

    func recordEncode(payloadHash: Int, sessionCount: Int) -> String? {
      encodes += 1
      if payloadHash != lastPayloadHash {
        payloadChanges += 1
        lastPayloadHash = payloadHash
      }
      let now = Date()
      let elapsed = now.timeIntervalSince(lastReportedAt)
      guard elapsed >= 5 else { return nil }
      let submitRate = Double(submissions) / elapsed
      let encodeRate = Double(encodes) / elapsed
      let changeRate = Double(payloadChanges) / elapsed
      let summary = String(
        format:
          "submissions=%d (%.1f/s) · encodes=%d (%.1f/s) · "
          + "payload changes=%d (%.1f/s) · sessions=%d",
        submissions, submitRate, encodes, encodeRate,
        payloadChanges, changeRate, sessionCount
      )
      submissions = 0
      encodes = 0
      payloadChanges = 0
      lastReportedAt = now
      return summary
    }
  }
  private static let telemetry = SaveTelemetry()

  /// Latest-value coalescer. `Sharing` fires `save` from every
  /// `withLock`'s defer — including when the body's early-return guards
  /// short-circuit and nothing actually mutated. Without coalescing the
  /// save queue did one full encode + atomic write per submission;
  /// telemetry showed bursts of `submissions=27 / payload changes=0`
  /// every few seconds.
  ///
  /// Coalesce by keeping only the most recent pending value plus the
  /// list of `SaveContinuation`s waiting to be told the save landed.
  /// One drain task runs at a time; when it finishes its current encode,
  /// it pulls the next pending value (whatever the latest submission set
  /// it to during the write) and continues. The drain task exits when
  /// no value is pending.
  ///
  /// Pending state is keyed by destination directory. Production only ever
  /// has one (`~/.supacool/sessions`), so this is the same single-store
  /// coalescing as before. But under test each `@Test` saves to its own temp
  /// directory; carrying the directory through the batch (instead of capturing
  /// it from whichever submission won the drain race) guarantees a batch is
  /// always written to ITS OWN store and never bleeds into another test's.
  private final class SaveCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingValues: [URL: [AgentSession]] = [:]
    private var pendingContinuations: [URL: [SaveContinuation]] = [:]
    private var draining = false

    /// Returns `true` iff the caller should dispatch a drain task.
    /// Subsequent submissions that arrive while a drain is in flight
    /// just update the pending value + continuation list and return false.
    func submit(_ value: [AgentSession], directory: URL, continuation: SaveContinuation) -> Bool {
      lock.lock()
      defer { lock.unlock() }
      pendingValues[directory] = value
      pendingContinuations[directory, default: []].append(continuation)
      if draining { return false }
      draining = true
      return true
    }

    /// Pulls the next per-directory batch to encode + write. Returns `nil`
    /// when nothing is pending; the drain flag is reset in that case so a
    /// future `submit` will spin up a new drain task.
    func takeBatch() -> (value: [AgentSession], directory: URL, continuations: [SaveContinuation])? {
      lock.lock()
      defer { lock.unlock() }
      guard let (directory, value) = pendingValues.first else {
        draining = false
        return nil
      }
      let conts = pendingContinuations[directory] ?? []
      pendingValues[directory] = nil
      pendingContinuations[directory] = nil
      return (value, directory, conts)
    }
  }
  private static let coalescer = SaveCoalescer()

  var id: AgentSessionsKeyID {
    @Dependency(\.sessionStorageLocations) var locations
    return AgentSessionsKeyID(directory: locations.directory)
  }

  func load(
    context _: LoadContext<[AgentSession]>,
    continuation: LoadContinuation<[AgentSession]>
  ) {
    // Derive the board by scanning the per-session directory (priority, then
    // most-recently-updated first). An undecodable session file is skipped,
    // never fatal.
    @Dependency(\.sessionStorageLocations) var locations
    continuation.resume(
      returning: SessionDirectoryStore.load(from: locations.directory)
    )
  }

  func subscribe(
    context _: LoadContext<[AgentSession]>,
    subscriber _: SharedSubscriber<[AgentSession]>
  ) -> SharedSubscription {
    SharedSubscription {}
  }

  func save(
    _ value: [AgentSession],
    context _: SaveContext,
    continuation: SaveContinuation
  ) {
    @Dependency(\.settingsFileStorage) var storage
    @Dependency(\.sessionStorageLocations) var locations
    // Resolve the dependencies on the calling thread — the DispatchQueue
    // block runs outside the dependency graph's TaskLocal scope.
    let resolvedStorage = storage
    let directory = locations.directory
    Task { await Self.telemetry.recordSubmission() }
    let shouldDrain = Self.coalescer.submit(value, directory: directory, continuation: continuation)
    guard shouldDrain else { return }
    Self.saveQueue.async {
      while let batch = Self.coalescer.takeBatch() {
        // Per-session atomic writes: only changed session files are rewritten,
        // dropped sessions' folders are removed. Removed sessions are recorded
        // to the crash-safety recovery store *before* their folders are
        // deleted, so a buggy/racing shrink can never silently lose data.
        SessionDirectoryStore.save(
          batch.value,
          to: batch.directory,
          recordRemovals: { removed in
            SessionRecoveryStore.recordRemovals(
              previous: removed,
              next: [],
              storage: resolvedStorage
            )
          }
        )
        for c in batch.continuations { c.resume() }
        Task {
          if let summary = await Self.telemetry.recordEncode(
            payloadHash: batch.value.map(\.id).hashValue,
            sessionCount: batch.value.count
          ) {
            Self.telemetryLogger.notice("\(summary, privacy: .public)")
          }
        }
      }
    }
  }
}

nonisolated extension SharedReaderKey where Self == AgentSessionsKey.Default {
  static var agentSessions: Self {
    Self[AgentSessionsKey(), default: []]
  }
}
