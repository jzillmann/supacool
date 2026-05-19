import Dependencies
import Foundation
import Sharing

/// `@Shared(.drafts)` — the list of unfinished "new terminal" prompts
/// the user has saved for later. Mirrors `BookmarksKey` mechanics; lives
/// in `drafts.json` next to bookmarks.
nonisolated struct DraftsKeyID: Hashable, Sendable {}

nonisolated struct DraftsKey: SharedKey {
  private static let logger = SupaLogger("Drafts")

  /// Off-main encode + write queue. See `AgentSessionsKey.saveQueue`.
  private static let saveQueue = DispatchQueue(
    label: "io.morethan.supacool.drafts-save",
    qos: .utility
  )

  var id: DraftsKeyID { DraftsKeyID() }

  static var fileURL: URL {
    SupacoolPaths.baseDirectory.appending(
      path: "drafts.json",
      directoryHint: .notDirectory
    )
  }

  func load(
    context _: LoadContext<[Draft]>,
    continuation: LoadContinuation<[Draft]>
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
      let drafts = try decoder.decode([Draft].self, from: data)
      continuation.resume(returning: drafts)
    } catch {
      Self.logger.warning(
        "Failed to decode drafts from \(Self.fileURL.path(percentEncoded: false)): \(error)"
      )
      continuation.resumeReturningInitialValue()
    }
  }

  func subscribe(
    context _: LoadContext<[Draft]>,
    subscriber _: SharedSubscriber<[Draft]>
  ) -> SharedSubscription {
    SharedSubscription {}
  }

  func save(
    _ value: [Draft],
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

nonisolated extension SharedReaderKey where Self == DraftsKey.Default {
  static var drafts: Self {
    Self[DraftsKey(), default: []]
  }
}
