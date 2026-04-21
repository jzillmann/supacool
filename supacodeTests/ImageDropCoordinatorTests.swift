import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import Supacool

/// Exercises the drop routing logic without shelling out: the transport
/// dependency is replaced with an in-memory recorder so the tests can
/// assert both the returned pasted path and the context (local vs.
/// remote) the coordinator inferred from `@Shared` state.
@MainActor
struct ImageDropCoordinatorTests {

  // MARK: Local path

  @Test func unknownSurfaceTreatedAsLocal() async {
    let recorder = TransportRecorder()
    let coordinator = ImageDropCoordinator(
      transport: ImageTransportClient(drop: recorder.capture)
    )
    let url = URL(fileURLWithPath: "/tmp/shot.png")

    let pasted = await coordinator.handleDrop(url: url, surfaceID: UUID())
    #expect(pasted == "/tmp/shot.png-PASTED")
    #expect(recorder.lastContext == .local)
  }

  @Test func localSessionRoutesThroughLocalContext() async {
    let sessionID = UUID()
    let session = AgentSession(
      id: sessionID,
      repositoryID: "/tmp/repo",
      worktreeID: "/tmp/repo",
      agent: .claude,
      initialPrompt: "x"
    )
    @Shared(.agentSessions) var sessions: [AgentSession]
    $sessions.withLock { $0 = [session] }

    let recorder = TransportRecorder()
    let coordinator = ImageDropCoordinator(
      transport: ImageTransportClient(drop: recorder.capture)
    )

    _ = await coordinator.handleDrop(url: URL(fileURLWithPath: "/tmp/a.png"), surfaceID: sessionID)
    #expect(recorder.lastContext == .local)
  }

  // MARK: Remote path

  @Test func remoteSessionRoutesThroughRemoteContextWithHostInfo() async {
    let hostID = UUID()
    let host = RemoteHost(
      id: hostID,
      sshAlias: "devbox",
      importedFromSSHConfig: true,
      overrides: RemoteHost.Overrides(remoteTmpdir: "/var/tmp")
    )
    let sessionID = UUID()
    let session = AgentSession(
      id: sessionID,
      repositoryID: "remote:devbox:/home/me/code",
      worktreeID: "remote:devbox:/home/me/code",
      agent: .claude,
      initialPrompt: "x",
      remoteWorkspaceID: UUID(),
      remoteHostID: hostID,
      tmuxSessionName: "supacool-foo"
    )

    @Shared(.agentSessions) var sessions: [AgentSession]
    @Shared(.remoteHosts) var hosts: [RemoteHost]
    $sessions.withLock { $0 = [session] }
    $hosts.withLock { $0 = [host] }

    let recorder = TransportRecorder()
    let coordinator = ImageDropCoordinator(
      transport: ImageTransportClient(drop: recorder.capture)
    )
    _ = await coordinator.handleDrop(url: URL(fileURLWithPath: "/tmp/a.png"), surfaceID: sessionID)

    #expect(recorder.lastContext == .remote(sshAlias: "devbox", remoteTmpdir: "/var/tmp"))
  }

  @Test func remoteUploadFailureBlocksThePaste() async {
    let hostID = UUID()
    let host = RemoteHost(id: hostID, sshAlias: "devbox", importedFromSSHConfig: true)
    let sessionID = UUID()
    var session = AgentSession(
      id: sessionID,
      repositoryID: "remote:devbox:/x",
      worktreeID: "remote:devbox:/x",
      agent: .claude,
      initialPrompt: "x"
    )
    session.remoteHostID = hostID
    session.remoteWorkspaceID = UUID()

    @Shared(.agentSessions) var sessions: [AgentSession]
    @Shared(.remoteHosts) var hosts: [RemoteHost]
    $sessions.withLock { $0 = [session] }
    $hosts.withLock { $0 = [host] }

    struct Boom: Error {}
    let coordinator = ImageDropCoordinator(
      transport: ImageTransportClient(drop: { _, _ in throw Boom() })
    )
    let pasted = await coordinator.handleDrop(
      url: URL(fileURLWithPath: "/tmp/a.png"),
      surfaceID: sessionID
    )
    // Remote upload failed → nil, so GhosttySurfaceView falls back to
    // its default behaviour (which we'd want to SUPPRESS, but nil is
    // safer than pasting a Mac-only path the remote agent can't read).
    #expect(pasted == nil)
  }

  @Test func localUploadFailureFallsBackToSourcePath() async {
    struct Boom: Error {}
    let coordinator = ImageDropCoordinator(
      transport: ImageTransportClient(drop: { _, _ in throw Boom() })
    )
    let pasted = await coordinator.handleDrop(
      url: URL(fileURLWithPath: "/tmp/a.png"),
      surfaceID: UUID()  // no matching session → local context
    )
    // Local fallback → paste the source path so the user still gets
    // *something* usable in the terminal.
    #expect(pasted == "/tmp/a.png")
  }

  // MARK: Test double

  final class TransportRecorder: @unchecked Sendable {
    var lastContext: ImageDropContext?

    func capture(url: URL, context: ImageDropContext) async throws -> String {
      lastContext = context
      return url.path(percentEncoded: false) + "-PASTED"
    }
  }
}
