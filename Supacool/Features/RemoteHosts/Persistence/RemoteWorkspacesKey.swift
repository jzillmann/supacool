import Dependencies
import Foundation
import Sharing

/// `@Shared(.remoteWorkspaces)` — named remote directories that can back
/// agent sessions. One host can have many workspaces (think: several repos
/// on one dev box). Mirrors `AgentSessionsKey` for persistence mechanics.
nonisolated struct RemoteWorkspacesKeyID: Hashable, Sendable {}

nonisolated struct RemoteWorkspacesKey: SharedKey {
  private static let logger = SupaLogger("RemoteWorkspaces")

  var id: RemoteWorkspacesKeyID { RemoteWorkspacesKeyID() }

  static var fileURL: URL {
    SupacodePaths.baseDirectory.appending(
      path: "remote-workspaces.json",
      directoryHint: .notDirectory
    )
  }

  func load(
    context _: LoadContext<[RemoteWorkspace]>,
    continuation: LoadContinuation<[RemoteWorkspace]>
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
      let workspaces = try decoder.decode([RemoteWorkspace].self, from: data)
      continuation.resume(returning: workspaces)
    } catch {
      Self.logger.warning(
        "Failed to decode remote workspaces from \(Self.fileURL.path(percentEncoded: false)): \(error)"
      )
      continuation.resumeReturningInitialValue()
    }
  }

  func subscribe(
    context _: LoadContext<[RemoteWorkspace]>,
    subscriber _: SharedSubscriber<[RemoteWorkspace]>
  ) -> SharedSubscription {
    SharedSubscription {}
  }

  func save(
    _ value: [RemoteWorkspace],
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

nonisolated extension SharedReaderKey where Self == RemoteWorkspacesKey.Default {
  static var remoteWorkspaces: Self {
    Self[RemoteWorkspacesKey(), default: []]
  }
}
