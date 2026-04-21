import ComposableArchitecture
import Foundation
import Observation

private nonisolated let imageDropLogger = SupaLogger("Supacool.ImageDrop")

/// Central broker for screenshot drops onto a Ghostty surface. Looks up
/// the surface's session in `@Shared(.agentSessions)`, decides whether
/// the drop is local or remote (via the session's `remoteWorkspaceID`),
/// and routes through `ImageTransportClient`. Surfaces progress + errors
/// for a tiny toast overlay anchored to the focused tab.
///
/// The coordinator is installed as the static `imageDropHandler` on
/// `GhosttySurfaceView` at app launch — that hook is the only upstream
/// touchpoint, so the entire remote-vs-local decision stays in the
/// Supacool subtree.
@MainActor
@Observable
final class ImageDropCoordinator {
  /// Most recent upload that's either in-flight or just completed.
  /// The toast view observes this; a 1.5s trailing timer clears
  /// successful entries so the UI doesn't stay noisy.
  private(set) var currentUpload: UploadState?

  private let transport: ImageTransportClient
  private var clearTask: Task<Void, Never>?

  struct UploadState: Equatable, Sendable {
    let id: UUID
    let filename: String
    let context: ImageDropContext
    var phase: Phase

    enum Phase: Equatable, Sendable {
      case uploading
      case succeeded(path: String)
      case failed(message: String)
    }
  }

  init(transport: ImageTransportClient) {
    self.transport = transport
  }

  /// Handles a dropped image URL for the given surface. Returns the path
  /// string to paste — nil means "fall back to default behaviour"
  /// (`GhosttySurfaceView` will then paste the local path as-is, which is
  /// still correct for local sessions when the transport fails).
  func handleDrop(url: URL, surfaceID: UUID) async -> String? {
    let context = contextFor(surfaceID: surfaceID)
    let filename = url.lastPathComponent
    let upload = UploadState(
      id: UUID(),
      filename: filename,
      context: context,
      phase: .uploading
    )
    currentUpload = upload
    clearTask?.cancel()

    do {
      let path = try await transport.drop(url, context)
      updatePhase(id: upload.id, .succeeded(path: path))
      scheduleClear(id: upload.id)
      return path
    } catch {
      let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
      imageDropLogger.warning("Image drop failed: \(message)")
      updatePhase(
        id: upload.id,
        .failed(message: message.isEmpty ? "Upload failed." : message)
      )
      scheduleClear(id: upload.id, after: .seconds(4))
      // Local failure → fall back to pasting the source path verbatim.
      // Remote failure → block the paste (the local path is meaningless).
      switch context {
      case .local: return url.path(percentEncoded: false)
      case .remote: return nil
      }
    }
  }

  // MARK: - Context lookup

  /// Looks up the surface in `@Shared` state. Unknown surface → local.
  /// We intentionally DON'T walk every tab on every drop: the session's
  /// id is its surface id (single-surface tabs per Supacool convention),
  /// so an O(n) scan over sessions is fine.
  private func contextFor(surfaceID: UUID) -> ImageDropContext {
    @Shared(.agentSessions) var sessions: [AgentSession]
    @Shared(.remoteHosts) var hosts: [RemoteHost]
    guard
      let session = sessions.first(where: { $0.id == surfaceID }),
      session.isRemote,
      let hostID = session.remoteHostID,
      let host = hosts.first(where: { $0.id == hostID })
    else {
      return .local
    }
    return .remote(sshAlias: host.sshAlias, remoteTmpdir: host.overrides.effectiveRemoteTmpdir)
  }

  // MARK: - State transitions

  private func updatePhase(id: UUID, _ phase: UploadState.Phase) {
    guard var upload = currentUpload, upload.id == id else { return }
    upload.phase = phase
    currentUpload = upload
  }

  private func scheduleClear(id: UUID, after delay: Duration = .milliseconds(1500)) {
    clearTask?.cancel()
    clearTask = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled else { return }
      await self?.clearIfStillCurrent(id: id)
    }
  }

  private func clearIfStillCurrent(id: UUID) {
    if currentUpload?.id == id {
      currentUpload = nil
    }
  }
}
