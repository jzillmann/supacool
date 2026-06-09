import Dependencies
import Foundation
import Sharing

/// `@Shared(.linearInbox)` — the list of Linear tickets the user pasted
/// into the Inbox to work through. Survives relaunch so you can close the
/// dialog and come back to pick the next one. Mirrors `DraftsKey`
/// mechanics; lives in `linear-inbox.json` next to drafts.
nonisolated struct LinearInboxKeyID: Hashable, Sendable {}

nonisolated struct LinearInboxKey: SharedKey {
  private static let logger = SupaLogger("LinearInbox")

  /// Off-main encode + write queue. See `AgentSessionsKey.saveQueue`.
  private static let saveQueue = DispatchQueue(
    label: "io.morethan.supacool.linear-inbox-save",
    qos: .utility
  )

  var id: LinearInboxKeyID { LinearInboxKeyID() }

  static var fileURL: URL {
    SupacoolPaths.baseDirectory.appending(
      path: "linear-inbox.json",
      directoryHint: .notDirectory
    )
  }

  func load(
    context _: LoadContext<[LinearTicket]>,
    continuation: LoadContinuation<[LinearTicket]>
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
      let tickets = try decoder.decode([LinearTicket].self, from: data)
      continuation.resume(returning: tickets)
    } catch {
      Self.logger.warning(
        "Failed to decode Linear inbox from \(Self.fileURL.path(percentEncoded: false)): \(error)"
      )
      continuation.resumeReturningInitialValue()
    }
  }

  func subscribe(
    context _: LoadContext<[LinearTicket]>,
    subscriber _: SharedSubscriber<[LinearTicket]>
  ) -> SharedSubscription {
    SharedSubscription {}
  }

  func save(
    _ value: [LinearTicket],
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

nonisolated extension SharedReaderKey where Self == LinearInboxKey.Default {
  static var linearInbox: Self {
    Self[LinearInboxKey(), default: []]
  }
}
