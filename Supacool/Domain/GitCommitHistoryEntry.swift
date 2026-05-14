import Foundation

/// One row in a lightweight `git log` view. Kept intentionally small so
/// toolbar/status affordances can load history without pulling full patches.
nonisolated struct GitCommitHistoryEntry: Equatable, Identifiable, Sendable {
  var id: String { hash }
  let hash: String
  let shortHash: String
  let date: Date
  let author: String
  let subject: String
}
