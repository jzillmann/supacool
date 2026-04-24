import Dependencies
import Foundation
import Sharing

/// `@Shared(.bookmarks)` — the list of per-repo bookmarks (saved
/// "new terminal" templates), persisted alongside agent sessions.
/// Mirrors `AgentSessionsKey` for persistence mechanics.
nonisolated struct BookmarksKeyID: Hashable, Sendable {}

nonisolated struct BookmarksKey: SharedKey {
  private static let logger = SupaLogger("Bookmarks")

  var id: BookmarksKeyID { BookmarksKeyID() }

  static var fileURL: URL {
    SupacoolPaths.baseDirectory.appending(
      path: "bookmarks.json",
      directoryHint: .notDirectory
    )
  }

  func load(
    context _: LoadContext<[Bookmark]>,
    continuation: LoadContinuation<[Bookmark]>
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
      let bookmarks = try decoder.decode([Bookmark].self, from: data)
      continuation.resume(returning: bookmarks)
    } catch {
      Self.logger.warning(
        "Failed to decode bookmarks from \(Self.fileURL.path(percentEncoded: false)): \(error)"
      )
      continuation.resumeReturningInitialValue()
    }
  }

  func subscribe(
    context _: LoadContext<[Bookmark]>,
    subscriber _: SharedSubscriber<[Bookmark]>
  ) -> SharedSubscription {
    SharedSubscription {}
  }

  func save(
    _ value: [Bookmark],
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

nonisolated extension SharedReaderKey where Self == BookmarksKey.Default {
  static var bookmarks: Self {
    Self[BookmarksKey(), default: []]
  }
}
