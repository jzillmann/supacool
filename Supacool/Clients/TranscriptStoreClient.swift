import ComposableArchitecture
import Foundation

private nonisolated let transcriptStoreLogger = SupaLogger("Supacool.TranscriptStore")

/// Housekeeping for the per-tab transcript files `TranscriptRecorder` writes.
///
/// The recorder only appends, and a file outlives its tab: deleting a card
/// keeps it, and so does every short-lived tab. Over months that grew to
/// ~19k files and ~10 GB, nearly all of them unreferenced. The launch sweep
/// deletes a file once no session or trashed session uses its id and it has
/// not been written for `transcriptStaleAge`.
nonisolated struct TranscriptStoreClient: Sendable {
  /// Deletes every `<uuid>.jsonl` whose uuid is not in `keep` and that was
  /// last modified before `modifiedBefore`. Returns how many were deleted.
  var sweep: @Sendable (_ keep: Set<UUID>, _ modifiedBefore: Date) async -> Int
}

extension TranscriptStoreClient: DependencyKey {
  static let liveValue = TranscriptStoreClient(
    sweep: { keep, modifiedBefore in
      await Task.detached(priority: .utility) {
        guard let directory = TranscriptReader.transcriptURL(rawTabID: UUID())?.deletingLastPathComponent() else {
          return 0
        }
        return sweepTranscripts(in: directory, keep: keep, modifiedBefore: modifiedBefore)
      }.value
    }
  )

  static let testValue = TranscriptStoreClient(sweep: { _, _ in 0 })
}

extension DependencyValues {
  var transcriptStore: TranscriptStoreClient {
    get { self[TranscriptStoreClient.self] }
    set { self[TranscriptStoreClient.self] = newValue }
  }
}

/// The sweep itself, on a directory, so tests can run it on a temp folder.
/// Files whose name is not `<uuid>.jsonl` are left alone.
nonisolated func sweepTranscripts(in directory: URL, keep: Set<UUID>, modifiedBefore: Date) -> Int {
  let fileManager = FileManager.default
  guard
    let files = try? fileManager.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.contentModificationDateKey],
      options: [.skipsHiddenFiles]
    )
  else { return 0 }
  var deleted = 0
  for file in files where file.pathExtension == "jsonl" {
    guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), !keep.contains(id),
      let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
      modified < modifiedBefore
    else { continue }
    do {
      try fileManager.removeItem(at: file)
      deleted += 1
    } catch {
      transcriptStoreLogger.warning("Could not delete transcript \(file.lastPathComponent): \(error)")
    }
  }
  if deleted > 0 {
    transcriptStoreLogger.info("Deleted \(deleted) stale transcripts")
  }
  return deleted
}
