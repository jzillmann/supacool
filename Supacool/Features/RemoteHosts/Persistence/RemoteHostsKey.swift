import Dependencies
import Foundation
import Sharing

/// `@Shared(.remoteHosts)` — the list of SSH targets Supacool knows about.
/// Mirrors `AgentSessionsKey` in every way; new file sibling in the
/// Supacool settings directory.
nonisolated struct RemoteHostsKeyID: Hashable, Sendable {}

nonisolated struct RemoteHostsKey: SharedKey {
  private static let logger = SupaLogger("RemoteHosts")

  var id: RemoteHostsKeyID { RemoteHostsKeyID() }

  static var fileURL: URL {
    SupacodePaths.baseDirectory.appending(
      path: "remote-hosts.json",
      directoryHint: .notDirectory
    )
  }

  func load(
    context _: LoadContext<[RemoteHost]>,
    continuation: LoadContinuation<[RemoteHost]>
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
      let hosts = try decoder.decode([RemoteHost].self, from: data)
      continuation.resume(returning: hosts)
    } catch {
      Self.logger.warning(
        "Failed to decode remote hosts from \(Self.fileURL.path(percentEncoded: false)): \(error)"
      )
      continuation.resumeReturningInitialValue()
    }
  }

  func subscribe(
    context _: LoadContext<[RemoteHost]>,
    subscriber _: SharedSubscriber<[RemoteHost]>
  ) -> SharedSubscription {
    SharedSubscription {}
  }

  func save(
    _ value: [RemoteHost],
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

nonisolated extension SharedReaderKey where Self == RemoteHostsKey.Default {
  static var remoteHosts: Self {
    Self[RemoteHostsKey(), default: []]
  }
}
