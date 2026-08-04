import Dependencies
import Foundation
import Sharing

/// `@Shared(.sessionGroups)` — the user's named groups of pinned sessions,
/// persisted to `~/.supacool/session-groups.json`. Mirrors `BookmarksKey`
/// for persistence mechanics (off-main encode + atomic write).
nonisolated struct SessionGroupsKeyID: Hashable, Sendable {}

nonisolated struct SessionGroupsKey: SharedKey {
  private static let logger = SupaLogger("SessionGroups")

  /// Off-main encode + write queue. See `BookmarksKey.saveQueue` /
  /// `AgentSessionsKey.saveQueue` for rationale: `Sharing.withLock`'s defer
  /// calls `save` synchronously, and a sync JSON encode + atomic write on
  /// every reducer mutation would block the main thread.
  private static let saveQueue = DispatchQueue(
    label: "io.morethan.supacool.session-groups-save",
    qos: .utility
  )

  var id: SessionGroupsKeyID { SessionGroupsKeyID() }

  static var fileURL: URL {
    SupacoolPaths.baseDirectory.appending(
      path: "session-groups.json",
      directoryHint: .notDirectory
    )
  }

  func load(
    context _: LoadContext<[SessionGroup]>,
    continuation: LoadContinuation<[SessionGroup]>
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
      let groups = try decoder.decode([SessionGroup].self, from: data)
      continuation.resume(returning: groups)
    } catch {
      Self.logger.warning(
        "Failed to decode session groups from \(Self.fileURL.path(percentEncoded: false)): \(error)"
      )
      continuation.resumeReturningInitialValue()
    }
  }

  func subscribe(
    context _: LoadContext<[SessionGroup]>,
    subscriber _: SharedSubscriber<[SessionGroup]>
  ) -> SharedSubscription {
    SharedSubscription {}
  }

  func save(
    _ value: [SessionGroup],
    context _: SaveContext,
    continuation: SaveContinuation
  ) {
    @Dependency(\.settingsFileStorage) var storage
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

nonisolated extension SharedReaderKey where Self == SessionGroupsKey.Default {
  static var sessionGroups: Self {
    Self[SessionGroupsKey(), default: []]
  }
}
