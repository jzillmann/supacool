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

  init(store: StoreOf<AppFeature>, terminalManager: WorktreeTerminalManager) {
    self.toolBox = MCPToolBox(store: store, terminalManager: terminalManager)
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
