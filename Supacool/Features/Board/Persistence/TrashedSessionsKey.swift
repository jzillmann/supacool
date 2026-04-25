import Dependencies
import Foundation
import Sharing

/// `@Shared(.trashedSessions)` — sessions the user removed from the
/// board, persisted between launches so the 3-day retention window
/// survives quitting the app. Mirrors AgentSessionsKey / BookmarksKey.
nonisolated struct TrashedSessionsKeyID: Hashable, Sendable {}

nonisolated struct TrashedSessionsKey: SharedKey {
  private static let logger = SupaLogger("TrashedSessions")

  var id: TrashedSessionsKeyID { TrashedSessionsKeyID() }

  static var fileURL: URL {
    SupacoolPaths.baseDirectory.appending(
      path: "trashed-sessions.json",
      directoryHint: .notDirectory
    )
  }

  func load(
    context _: LoadContext<[TrashedSession]>,
    continuation: LoadContinuation<[TrashedSession]>
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
      let trashed = try decoder.decode([TrashedSession].self, from: data)
      continuation.resume(returning: trashed)
    } catch {
      Self.logger.warning(
        "Failed to decode trashed sessions from \(Self.fileURL.path(percentEncoded: false)): \(error)"
      )
      continuation.resumeReturningInitialValue()
    }
  }

  func subscribe(
    context _: LoadContext<[TrashedSession]>,
    subscriber _: SharedSubscriber<[TrashedSession]>
  ) -> SharedSubscription {
    SharedSubscription {}
  }

  func save(
    _ value: [TrashedSession],
    context _: SaveContext,
    continuation: SaveContinuation
  ) {
    @Dependency(\.settingsFileStorage) var storage
    do {
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(value)
      try storage.save(data, Self.fileURL)
      continuation.resume()
    } catch {
      continuation.resume(throwing: error)
    }
  }
}

nonisolated extension SharedReaderKey where Self == TrashedSessionsKey.Default {
  static var trashedSessions: Self {
    Self[TrashedSessionsKey(), default: []]
  }
}
