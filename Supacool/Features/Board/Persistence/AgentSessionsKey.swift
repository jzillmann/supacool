import Dependencies
import Foundation
import OSLog
import Sharing

/// `@Shared(.agentSessions)` — the list of Supacool board sessions, persisted
/// to JSON alongside supacode's other settings files.
nonisolated struct AgentSessionsKeyID: Hashable, Sendable {}

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
  private final class SaveCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingValue: [AgentSession]?
    private var pendingContinuations: [SaveContinuation] = []
    private var draining = false

    /// Returns `true` iff the caller should dispatch a drain task.
    /// Subsequent submissions that arrive while a drain is in flight
    /// just update the pending value + continuation list and return false.
    func submit(_ value: [AgentSession], continuation: SaveContinuation) -> Bool {
      lock.lock()
      defer { lock.unlock() }
      pendingValue = value
      pendingContinuations.append(continuation)
      if draining { return false }
      draining = true
      return true
    }

    /// Pulls the next batch to encode + write. Returns `nil` when the
    /// queue is empty; the drain flag is reset in that case so a future
    /// `submit` will spin up a new drain task.
    func takeBatch() -> (value: [AgentSession], continuations: [SaveContinuation])? {
      lock.lock()
      defer { lock.unlock() }
      guard let value = pendingValue else {
        draining = false
        return nil
      }
      let conts = pendingContinuations
      pendingValue = nil
      pendingContinuations = []
      return (value, conts)
    }
  }
  private static let coalescer = SaveCoalescer()

  /// Snapshot of the most recently persisted set, used by the crash-safety
  /// backstop to detect sessions that disappear between writes. Touched only
  /// on `saveQueue` (serial), but guarded so the type stays `Sendable`.
  /// Seeded lazily from disk on the first save so a session dropped by the
  /// very first post-launch mutation (the 2026-06-04 crash scenario) is still
  /// caught.
  private static let lastPersisted = LockIsolated<[AgentSession]?>(nil)

  private static func previouslyPersisted(storage: SettingsFileStorage) -> [AgentSession]? {
    if let cached = lastPersisted.value { return cached }
    guard let data = try? storage.load(Self.fileURL) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode([AgentSession].self, from: data)
  }

  var id: AgentSessionsKeyID { AgentSessionsKeyID() }

  static var fileURL: URL {
    SupacoolPaths.baseDirectory.appending(
      path: "agent-sessions.json",
      directoryHint: .notDirectory
    )
  }

  func load(
    context _: LoadContext<[AgentSession]>,
    continuation: LoadContinuation<[AgentSession]>
  ) {
    @Dependency(\.settingsFileStorage) var storage
    let data: Data
    do {
      data = try storage.load(Self.fileURL)
    } catch {
      continuation.resumeReturningInitialValue()
      return
    }
    do {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      let sessions = try decoder.decode([AgentSession].self, from: data)
      continuation.resume(returning: sessions)
    } catch {
      Self.logger.warning(
        "Failed to decode agent sessions from \(Self.fileURL.path(percentEncoded: false)): \(error)"
      )
      continuation.resumeReturningInitialValue()
    }
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
    // Resolve the dependency on the calling thread — the DispatchQueue
    // block runs outside the dependency graph's TaskLocal scope.
    let resolvedStorage = storage
    Task { await Self.telemetry.recordSubmission() }
    let shouldDrain = Self.coalescer.submit(value, continuation: continuation)
    guard shouldDrain else { return }
    Self.saveQueue.async {
      while let batch = Self.coalescer.takeBatch() {
        do {
          let encoder = JSONEncoder()
          encoder.dateEncodingStrategy = .iso8601
          encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
          let data = try encoder.encode(batch.value)
          let payloadHash = data.hashValue
          let sessionCount = batch.value.count
          // Crash-safety backstop: before overwriting the file with a
          // smaller set, record any dropped sessions to the recovery store
          // FIRST. A crash between this and the main write leaves the old
          // (atomic) file intact; a crash after leaves the dropped sessions
          // recoverable. Either way nothing is silently lost. Never throws.
          if let previous = Self.previouslyPersisted(storage: resolvedStorage) {
            SessionRecoveryStore.recordRemovals(
              previous: previous,
              next: batch.value,
              storage: resolvedStorage
            )
          }
          try resolvedStorage.save(data, Self.fileURL)
          Self.lastPersisted.setValue(batch.value)
          for c in batch.continuations { c.resume() }
          Task {
            if let summary = await Self.telemetry.recordEncode(
              payloadHash: payloadHash,
              sessionCount: sessionCount
            ) {
              Self.telemetryLogger.notice("\(summary, privacy: .public)")
            }
          }
        } catch {
          for c in batch.continuations { c.resume(throwing: error) }
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
