import Dependencies
import Foundation
import Sharing

/// `@Shared(.linearInbox)` — the Linear tickets the user pasted into the
/// Inbox to work through, **bucketed per repository** (`Repository.ID` →
/// tickets). The inbox is repo-scoped: each repo keeps its own worklist and
/// its own recent-ticket import scope. Survives relaunch so you can close the
/// dialog and come back to pick the next one. Mirrors `DraftsKey` mechanics;
/// lives in `linear-inbox.json` next to drafts.
///
/// Pre-repo-scoping builds persisted a bare `[LinearTicket]` array. `load`
/// stays tolerant of that legacy shape by parking it under
/// ``legacyBucketKey``; `LinearInboxFeature` redistributes those tickets into
/// the right repo buckets (by ticket prefix) on first open, so no worklist is
/// lost on upgrade.
nonisolated struct LinearInboxKeyID: Hashable, Sendable {}

nonisolated struct LinearInboxKey: SharedKey {
  private static let logger = SupaLogger("LinearInbox")

  /// Reserved bucket holding tickets recovered from the pre-repo-scoping
  /// `[LinearTicket]` file. Never a real `Repository.ID` (those are absolute
  /// repo root paths, always non-empty), so it can't collide with a repo.
  static let legacyBucketKey = ""

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
    context _: LoadContext<[String: [LinearTicket]]>,
    continuation: LoadContinuation<[String: [LinearTicket]]>
  ) {
    @Dependency(\.settingsFileStorage) var storage
    let data: Data
    do {
      data = try storage.load(Self.fileURL)
    } catch {
      continuation.resumeReturningInitialValue()
      return
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    if let buckets = try? decoder.decode([String: [LinearTicket]].self, from: data) {
      continuation.resume(returning: buckets)
      return
    }
    // Legacy shape: a bare `[LinearTicket]`. Park it under the reserved
    // bucket so the feature can redistribute it per-repo on first open.
    if let legacy = try? decoder.decode([LinearTicket].self, from: data) {
      continuation.resume(returning: [Self.legacyBucketKey: legacy])
      return
    }
    Self.logger.warning(
      "Failed to decode Linear inbox from \(Self.fileURL.path(percentEncoded: false))"
    )
    continuation.resumeReturningInitialValue()
  }

  func subscribe(
    context _: LoadContext<[String: [LinearTicket]]>,
    subscriber _: SharedSubscriber<[String: [LinearTicket]]>
  ) -> SharedSubscription {
    SharedSubscription {}
  }

  func save(
    _ value: [String: [LinearTicket]],
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
    Self[LinearInboxKey(), default: [:]]
  }
}
