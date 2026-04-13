import Dependencies
import Foundation
import Sharing

/// Persisted user filters for the board: which registered repos are currently
/// selected (empty = "show all").
nonisolated struct BoardFilters: Equatable, Codable, Sendable {
  /// Repository IDs (their root paths). Empty means "show all repos".
  var selectedRepositoryIDs: Set<String>

  init(selectedRepositoryIDs: Set<String> = []) {
    self.selectedRepositoryIDs = selectedRepositoryIDs
  }

  static let empty = BoardFilters()

  /// True when no explicit filter is active and every registered repo should
  /// be visible.
  var showsAllRepositories: Bool { selectedRepositoryIDs.isEmpty }

  func includes(repositoryID: String) -> Bool {
    showsAllRepositories || selectedRepositoryIDs.contains(repositoryID)
  }

  // Forward-compatible Codable — convention documented in
  // Supacool/docs/persistence-convention.md. Missing fields decode to
  // empty/default so adding new fields in future versions doesn't wipe
  // existing saved filters.
  enum CodingKeys: String, CodingKey { case selectedRepositoryIDs }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    selectedRepositoryIDs = try c.decodeIfPresent(Set<String>.self, forKey: .selectedRepositoryIDs) ?? []
  }
}

nonisolated struct BoardFiltersKeyID: Hashable, Sendable {}

nonisolated struct BoardFiltersKey: SharedKey {
  private static let logger = SupaLogger("BoardFilters")

  var id: BoardFiltersKeyID { BoardFiltersKeyID() }

  static var fileURL: URL {
    SupacodePaths.baseDirectory.appending(
      path: "board-filters.json",
      directoryHint: .notDirectory
    )
  }

  func load(
    context _: LoadContext<BoardFilters>,
    continuation: LoadContinuation<BoardFilters>
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
      let filters = try JSONDecoder().decode(BoardFilters.self, from: data)
      continuation.resume(returning: filters)
    } catch {
      Self.logger.warning(
        "Failed to decode board filters from \(Self.fileURL.path(percentEncoded: false)): \(error)"
      )
      continuation.resumeReturningInitialValue()
    }
  }

  func subscribe(
    context _: LoadContext<BoardFilters>,
    subscriber _: SharedSubscriber<BoardFilters>
  ) -> SharedSubscription {
    SharedSubscription {}
  }

  func save(
    _ value: BoardFilters,
    context _: SaveContext,
    continuation: SaveContinuation
  ) {
    @Dependency(\.settingsFileStorage) var storage
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(value)
      try storage.save(data, Self.fileURL)
      continuation.resume()
    } catch {
      continuation.resume(throwing: error)
    }
  }
}

nonisolated extension SharedReaderKey where Self == BoardFiltersKey.Default {
  static var boardFilters: Self {
    Self[BoardFiltersKey(), default: BoardFilters.empty]
  }
}
