import Combine
import ComposableArchitecture
import Foundation
import MCP
import Observation

private nonisolated let mcpLogger = SupaLogger("Supacool.MCPControl")

/// The remote-control plane: an in-process MCP server exposing read-only board
/// tools (`list_sessions`, `read_session`) over streamable HTTP on localhost.
///
/// Assembly: `MCPHTTPListener` (loopback NWListener) → the SDK's
/// `StatelessHTTPServerTransport` (JSON-RPC framing + origin/bearer validation)
/// → `MCPToolBox` (handlers reading board state on the main actor).
///
/// Owned by `SupacoolApp` for the app's lifetime; whether it listens is driven
/// by the remote-control settings toggle.
@MainActor
@Observable
final class MCPControlServer {
  enum Status: Equatable {
    case stopped
    case starting
    case running(port: UInt16)
    case failed(reason: String)
  }

  private(set) var status: Status = .stopped

  private let toolBox: MCPToolBox
  private var server: Server?
  private var listener: MCPHTTPListener?
  @ObservationIgnored @Shared(.settingsFile) private var settingsFile
  private var settingsObservation: Task<Void, Never>?

  init(store: StoreOf<AppFeature>, terminalManager: WorktreeTerminalManager) {
    self.toolBox = MCPToolBox(store: store, terminalManager: terminalManager)
  }

  /// Follows the persisted remote-control settings for the app's lifetime:
  /// starts the server on launch when enabled, stops on toggle-off, restarts
  /// on a port change. Deliberately NOT window-bound (no `.task`/`.onChange`
  /// on a view) — the control plane must run even when every window is closed.
  func startFollowingSettings() {
    guard settingsObservation == nil else { return }
    // No Combine operators here: under default-MainActor isolation an operator
    // closure inherits MainActor but gets invoked on Combine's thread —
    // dispatch_assert_queue trap. Map/dedup inside the MainActor loop instead.
    let values = $settingsFile.publisher.values
    settingsObservation = Task { [weak self] in
      var lastConfig: RemoteControlConfig?
      for await file in values {
        guard let self else { return }
        let config = RemoteControlConfig(
          enabled: file.global.remoteControlServerEnabled,
          port: UInt16(clamping: file.global.remoteControlServerPort)
        )
        guard config != lastConfig else { continue }
        lastConfig = config
        await self.apply(config)
      }
    }
  }

  private struct RemoteControlConfig: Equatable {
    let enabled: Bool
    let port: UInt16
  }

  private func apply(_ config: RemoteControlConfig) async {
    guard config.enabled else {
      if status != .stopped {
        await stop()
      }
      return
    }
    if case .running(let current) = status, current == config.port {
      return
    }
    await teardown()
    status = .stopped
    await start(port: config.port)
  }

  func start(port: UInt16) async {
    guard status == .stopped || status.isFailed else { return }
    status = .starting
    do {
      let token = try MCPAuthToken.loadOrCreate()
      let transport = Self.makeTransport(secret: token)

      let version =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
      let toolBox = self.toolBox
      let server = await Server(
        name: "supacool",
        version: version,
        instructions: """
          Read-only view of the Supacool Matrix Board — the user's fleet of \
          terminal agent sessions. Use list_sessions for an overview and \
          read_session to see what a specific session is doing or asking.
          """,
        capabilities: .init(tools: .init(listChanged: false))
      )
      .withMethodHandler(ListTools.self) { _ in
        ListTools.Result(tools: MCPToolBox.definitions)
      }
      .withMethodHandler(CallTool.self) { parameters in
        try await toolBox.call(name: parameters.name, arguments: parameters.arguments)
      }

      try await server.start(transport: transport)

      let listener = MCPHTTPListener(port: port) { request in
        // Single-endpoint server: everything but /mcp is a 404, the
        // transport's own routing handles method/validation errors.
        guard request.path == "/mcp" else {
          return .error(statusCode: 404, MCPError.invalidRequest("Not Found"))
        }
        return await transport.handleRequest(request)
      }
      try await listener.start()

      self.server = server
      self.listener = listener
      status = .running(port: port)
      mcpLogger.info("remote-control MCP server running on 127.0.0.1:\(port)")
    } catch {
      await teardown()
      let reason = Self.describeStartFailure(error)
      status = .failed(reason: reason)
      mcpLogger.warning("remote-control MCP server failed to start: \(reason)")
    }
  }

  func stop() async {
    await teardown()
    status = .stopped
    mcpLogger.info("remote-control MCP server stopped")
  }

  private func teardown() async {
    await listener?.stop()
    listener = nil
    await server?.stop()
    server = nil
  }

  /// The production validation pipeline; shared with tests so auth behavior
  /// is exercised exactly as deployed.
  nonisolated static func makeTransport(secret: String) -> StatelessHTTPServerTransport {
    StatelessHTTPServerTransport(
      validationPipeline: StandardValidationPipeline(validators: [
        OriginValidator.localhost(),
        StaticBearerValidator(secret: secret),
        AcceptHeaderValidator(mode: .jsonOnly),
        ContentTypeValidator(),
        ProtocolVersionValidator(),
      ])
    )
  }

  private static func describeStartFailure(_ error: Error) -> String {
    if case MCPHTTPListener.ListenerError.failedToStart(let detail) = error {
      return "listener failed to start: \(detail)"
    }
    return error.localizedDescription
  }
}

extension MCPControlServer.Status {
  var isFailed: Bool {
    if case .failed = self { return true }
    return false
  }
}
