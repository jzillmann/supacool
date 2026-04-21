import ComposableArchitecture
import Foundation

private nonisolated let imageTransportLogger = SupaLogger("Supacool.ImageTransport")

/// Copies or uploads a dropped image into a location where the coding
/// agent can read it, returning the path string to paste into the
/// terminal. Local sessions write to `$TMPDIR/supacool/`; remote
/// sessions scp over the spawn flow's existing ControlMaster tunnel to
/// `<remoteTmpdir>/` on the host.
nonisolated struct ImageTransportClient: Sendable {
  var drop: @Sendable (_ sourceURL: URL, _ context: ImageDropContext) async throws -> String
}

/// Where the dropped image needs to land. `.remote` carries the ssh
/// alias + remote tmpdir so the client can shell out to `scp` against
/// the same multiplex ControlPath the spawn flow established — the
/// upload is effectively one packet inside the open tunnel.
nonisolated enum ImageDropContext: Sendable, Equatable {
  case local
  case remote(sshAlias: String, remoteTmpdir: String)
}

extension ImageTransportClient: DependencyKey {
  static let liveValue = live()

  static func live(shell: ShellClient = .liveValue) -> ImageTransportClient {
    ImageTransportClient(
      drop: { sourceURL, context in
        switch context {
        case .local:
          return try await copyLocally(sourceURL: sourceURL)
        case .remote(let alias, let tmpdir):
          return try await uploadViaSCP(sourceURL: sourceURL, alias: alias, tmpdir: tmpdir, shell: shell)
        }
      }
    )
  }

  static let testValue = ImageTransportClient(
    drop: { _, _ in
      struct Unimplemented: Error {}
      throw Unimplemented()
    }
  )
}

extension DependencyValues {
  var imageTransportClient: ImageTransportClient {
    get { self[ImageTransportClient.self] }
    set { self[ImageTransportClient.self] = newValue }
  }
}

// MARK: - Local copy

/// Writes the image into a Supacool-owned subdirectory of NSTemporaryDirectory
/// with a fresh UUID — never the user's original path, so repeated drops of
/// the same screenshot don't clobber each other.
nonisolated func copyLocally(sourceURL: URL) async throws -> String {
  let ext = sourceURL.pathExtension.isEmpty ? "png" : sourceURL.pathExtension
  let destinationDir = URL(fileURLWithPath: NSTemporaryDirectory())
    .appending(path: "supacool", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(
    at: destinationDir, withIntermediateDirectories: true, attributes: nil
  )
  let filename = "supacool-\(UUID().uuidString.lowercased().prefix(12)).\(ext)"
  let destinationURL = destinationDir.appending(
    path: String(filename), directoryHint: .notDirectory
  )
  try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
  return destinationURL.path(percentEncoded: false)
}

// MARK: - Remote upload via scp over ControlMaster

/// scp's the file to `<tmpdir>/supacool-<uuid>.<ext>` on the given host.
/// Reuses the ssh ControlPath the spawn flow created (`~/.supacool/ssh/...`)
/// so there's no second TCP handshake — the upload multiplexes onto the
/// open connection.
nonisolated func uploadViaSCP(
  sourceURL: URL,
  alias: String,
  tmpdir: String,
  shell: ShellClient
) async throws -> String {
  let ext = sourceURL.pathExtension.isEmpty ? "png" : sourceURL.pathExtension
  let filename = "supacool-\(UUID().uuidString.lowercased().prefix(12)).\(ext)"
  let remotePath = "\(tmpdir)/\(filename)"

  let envURL = URL(fileURLWithPath: "/usr/bin/env")
  let arguments = [
    "scp",
    "-o", "ControlPath=~/.supacool/ssh/%r@%h:%p",
    sourceURL.path(percentEncoded: false),
    "\(alias):\(remotePath)",
  ]

  do {
    _ = try await shell.runLogin(envURL, arguments, nil, log: false)
  } catch {
    imageTransportLogger.warning(
      "scp upload failed for \(alias): \(error.localizedDescription)"
    )
    throw error
  }
  return remotePath
}
