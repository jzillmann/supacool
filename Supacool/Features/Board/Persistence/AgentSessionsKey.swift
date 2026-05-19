import Dependencies
import Foundation
import Sharing

/// `@Shared(.agentSessions)` — the list of Supacool board sessions, persisted
/// to JSON alongside supacode's other settings files.
nonisolated struct AgentSessionsKeyID: Hashable, Sendable {}

nonisolated struct AgentSessionsKey: SharedKey {
  private static let logger = SupaLogger("AgentSessions")

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
    Self.saveQueue.async {
      do {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try resolvedStorage.save(data, Self.fileURL)
        continuation.resume()
      } catch {
        continuation.resume(throwing: error)
      }
    }
  }
}

nonisolated extension SharedReaderKey where Self == AgentSessionsKey.Default {
  static var agentSessions: Self {
    Self[AgentSessionsKey(), default: []]
  }
}
