import Foundation
import MCP
import Testing

@testable import Supacool

struct MCPAuthTokenTests {
  private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "mcp-token-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @Test func loadOrCreateGeneratesThenReturnsStableToken() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let first = try MCPAuthToken.loadOrCreate(in: dir)
    #expect(first.count == 64)
    #expect(first.allSatisfy { $0.isHexDigit })
    let second = try MCPAuthToken.loadOrCreate(in: dir)
    #expect(first == second)
  }

  @Test func tokenFileIsOwnerOnly() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    try MCPAuthToken.regenerate(in: dir)
    let attributes = try FileManager.default.attributesOfItem(
      atPath: MCPAuthToken.tokenURL(in: dir).path
    )
    #expect((attributes[.posixPermissions] as? Int) == 0o600)
  }

  @Test func regenerateReplacesToken() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let first = try MCPAuthToken.loadOrCreate(in: dir)
    let second = try MCPAuthToken.regenerate(in: dir)
    #expect(first != second)
    let reloaded = try MCPAuthToken.loadOrCreate(in: dir)
    #expect(reloaded == second)
  }

  @Test func constantTimeEqualsComparesCorrectly() {
    #expect(MCPAuthToken.constantTimeEquals("abc123", "abc123"))
    #expect(!MCPAuthToken.constantTimeEquals("abc123", "abc124"))
    #expect(!MCPAuthToken.constantTimeEquals("abc123", "abc1234"))
    #expect(!MCPAuthToken.constantTimeEquals("", "a"))
    #expect(MCPAuthToken.constantTimeEquals("", ""))
  }
}

struct StaticBearerValidatorTests {
  private let context = HTTPValidationContext(
    httpMethod: "POST",
    sessionID: nil,
    isInitializationRequest: false,
    supportedProtocolVersions: []
  )

  @Test func missingAuthorizationIs401() {
    let validator = StaticBearerValidator(secret: "s3cret")
    let response = validator.validate(HTTPRequest(method: "POST"), context: context)
    #expect(response?.statusCode == 401)
    #expect(response?.headers["WWW-Authenticate"] == "Bearer")
  }

  @Test func wrongTokenIs401() {
    let validator = StaticBearerValidator(secret: "s3cret")
    let request = HTTPRequest(method: "POST", headers: ["Authorization": "Bearer nope"])
    #expect(validator.validate(request, context: context)?.statusCode == 401)
  }

  @Test func nonBearerSchemeIs401() {
    let validator = StaticBearerValidator(secret: "s3cret")
    let request = HTTPRequest(method: "POST", headers: ["Authorization": "Basic czNjcmV0"])
    #expect(validator.validate(request, context: context)?.statusCode == 401)
  }

  @Test func correctTokenPasses() {
    let validator = StaticBearerValidator(secret: "s3cret")
    let request = HTTPRequest(method: "POST", headers: ["Authorization": "Bearer s3cret"])
    #expect(validator.validate(request, context: context) == nil)
  }
}

/// Full-stack round trip: loopback socket → HTTP parse → production validation
/// pipeline → SDK server → JSON-RPC response. Proves a real MCP client can
/// initialize and list tools with the right token, and gets 401 without it.
struct MCPControlServerEndToEndTests {
  private static let secret = "test-secret-token"

  private func startStack() async throws -> (listener: MCPHTTPListener, server: Server, port: UInt16) {
    let transport = MCPControlServer.makeTransport(secret: Self.secret)
    let server = await Server(
      name: "supacool-test",
      version: "0",
      capabilities: .init(tools: .init(listChanged: false))
    )
    .withMethodHandler(ListTools.self) { _ in
      ListTools.Result(tools: MCPToolBox.readDefinitions)
    }
    try await server.start(transport: transport)

    let port = UInt16.random(in: 30000..<60000)
    let listener = MCPHTTPListener(port: port) { request in
      guard request.path == "/mcp" else {
        return .error(statusCode: 404, MCPError.invalidRequest("Not Found"))
      }
      return await transport.handleRequest(request)
    }
    try await listener.start()
    return (listener, server, port)
  }

  private func post(
    _ json: String,
    port: UInt16,
    token: String?
  ) async throws -> (status: Int, body: [String: Any]) {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
    request.httpMethod = "POST"
    request.httpBody = Data(json.utf8)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let token {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = try #require(response as? HTTPURLResponse).statusCode
    let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    return (status, body)
  }

  private static let initializeRequest = """
    {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18",\
    "capabilities":{},"clientInfo":{"name":"test","version":"0"}}}
    """

  @Test func initializeAndListToolsWithValidToken() async throws {
    let stack = try await startStack()
    defer { Task { await stack.listener.stop(); await stack.server.stop() } }

    let initialize = try await post(Self.initializeRequest, port: stack.port, token: Self.secret)
    #expect(initialize.status == 200)
    let serverInfo = ((initialize.body["result"] as? [String: Any])?["serverInfo"]) as? [String: Any]
    #expect(serverInfo?["name"] as? String == "supacool-test")

    let list = try await post(
      #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#,
      port: stack.port,
      token: Self.secret
    )
    #expect(list.status == 200)
    let tools = ((list.body["result"] as? [String: Any])?["tools"]) as? [[String: Any]]
    let names = Set(tools?.compactMap { $0["name"] as? String } ?? [])
    #expect(names == ["list_sessions", "read_session"])
  }

  @Test func missingTokenIs401() async throws {
    let stack = try await startStack()
    defer { Task { await stack.listener.stop(); await stack.server.stop() } }

    let result = try await post(Self.initializeRequest, port: stack.port, token: nil)
    #expect(result.status == 401)
  }

  @Test func wrongTokenIs401() async throws {
    let stack = try await startStack()
    defer { Task { await stack.listener.stop(); await stack.server.stop() } }

    let result = try await post(Self.initializeRequest, port: stack.port, token: "wrong")
    #expect(result.status == 401)
  }

  @Test func unknownPathIs404() async throws {
    let stack = try await startStack()
    defer { Task { await stack.listener.stop(); await stack.server.stop() } }

    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(stack.port)/other")!)
    request.httpMethod = "POST"
    request.httpBody = Data("{}".utf8)
    let (_, response) = try await URLSession.shared.data(for: request)
    let http = try #require(response as? HTTPURLResponse)
    #expect(http.statusCode == 404)
  }
}
