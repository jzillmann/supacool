import Foundation
import MCP
import Testing

@testable import Supacool

struct MCPHTTPListenerTests {
  // MARK: - Head parsing

  @Test func headerEndIndexFindsTerminator() {
    let data = Data("POST /mcp HTTP/1.1\r\nHost: x\r\n\r\nbody".utf8)
    #expect(MCPHTTPListener.headerEndIndex(in: data) == 27)
  }

  @Test func headerEndIndexNilWhileIncomplete() {
    let data = Data("POST /mcp HTTP/1.1\r\nHost: x\r\n".utf8)
    #expect(MCPHTTPListener.headerEndIndex(in: data) == nil)
  }

  @Test func parseHeadReadsMethodPathAndHeaders() throws {
    let head = Data("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:4519\r\nContent-Type: application/json\r\n".utf8)
    let parsed = try #require(MCPHTTPListener.parseHead(head))
    #expect(parsed.method == "POST")
    #expect(parsed.path == "/mcp")
    #expect(parsed.headers["Host"] == "127.0.0.1:4519")
    #expect(parsed.headers["Content-Type"] == "application/json")
  }

  @Test func parseHeadTrimsHeaderWhitespace() throws {
    let head = Data("GET / HTTP/1.1\r\nAuthorization:   Bearer abc  \r\n".utf8)
    let parsed = try #require(MCPHTTPListener.parseHead(head))
    #expect(parsed.headers["Authorization"] == "Bearer abc")
  }

  @Test func parseHeadRejectsMalformedRequestLine() {
    #expect(MCPHTTPListener.parseHead(Data("POST /mcp\r\n".utf8)) == nil)
    #expect(MCPHTTPListener.parseHead(Data("POST /mcp SPDY/3\r\n".utf8)) == nil)
    #expect(MCPHTTPListener.parseHead(Data("".utf8)) == nil)
  }

  @Test func parseHeadRejectsHeaderWithoutColon() {
    let head = Data("POST /mcp HTTP/1.1\r\nBadHeaderLine\r\n".utf8)
    #expect(MCPHTTPListener.parseHead(head) == nil)
  }

  @Test func declaredContentLengthIsCaseInsensitiveAndDefaultsToZero() {
    #expect(MCPHTTPListener.declaredContentLength(in: ["content-length": "42"]) == 42)
    #expect(MCPHTTPListener.declaredContentLength(in: ["Content-Length": "7"]) == 7)
    #expect(MCPHTTPListener.declaredContentLength(in: [:]) == 0)
    #expect(MCPHTTPListener.declaredContentLength(in: ["Content-Length": "not-a-number"]) == 0)
  }

  // MARK: - Serialization

  @Test func serializeRawProducesValidResponse() throws {
    let data = MCPHTTPListener.serializeRaw(
      statusCode: 200,
      headers: ["Content-Type": "application/json"],
      body: Data("{}".utf8)
    )
    let text = try #require(String(data: data, encoding: .utf8))
    #expect(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
    #expect(text.contains("Content-Length: 2\r\n"))
    #expect(text.contains("Connection: close\r\n"))
    #expect(text.contains("Content-Type: application/json\r\n"))
    #expect(text.hasSuffix("\r\n\r\n{}"))
  }

  @Test func serializeMapsTransportErrorResponses() throws {
    let response = HTTPResponse.error(statusCode: 405, MCPError.invalidRequest("Method Not Allowed"))
    let data = MCPHTTPListener.serialize(response)
    let text = try #require(String(data: data, encoding: .utf8))
    #expect(text.hasPrefix("HTTP/1.1 405 Method Not Allowed\r\n"))
    // Error responses carry a JSON-RPC error body.
    #expect(text.contains("\"jsonrpc\""))
  }

  @Test func serializeAcceptedHasEmptyBody() throws {
    let data = MCPHTTPListener.serialize(HTTPResponse.accepted())
    let text = try #require(String(data: data, encoding: .utf8))
    #expect(text.hasPrefix("HTTP/1.1 202 Accepted\r\n"))
    #expect(text.contains("Content-Length: 0\r\n"))
  }

  // MARK: - Socket round-trip

  /// One end-to-end pass over a real loopback socket: proves accept → parse →
  /// handler → serialize → respond works outside the pure functions.
  @Test func roundTripServesEchoHandler() async throws {
    let port = UInt16.random(in: 30000..<60000)
    let listener = MCPHTTPListener(port: port) { request in
      HTTPResponse.data(
        Data("echo:\(request.method):\(request.path ?? "-")".utf8),
        headers: ["Content-Type": "text/plain"]
      )
    }
    try await listener.start()
    defer { Task { await listener.stop() } }

    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
    request.httpMethod = "POST"
    request.httpBody = Data("{\"jsonrpc\":\"2.0\"}".utf8)
    let (body, response) = try await URLSession.shared.data(for: request)

    let http = try #require(response as? HTTPURLResponse)
    #expect(http.statusCode == 200)
    #expect(String(data: body, encoding: .utf8) == "echo:POST:/mcp")
  }
}
