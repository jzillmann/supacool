import Foundation
import MCP
import Network

private nonisolated let listenerLogger = SupaLogger("Supacool.MCPHTTPListener")

/// Minimal HTTP/1.1 listener bridging Network.framework to the MCP SDK's
/// framework-agnostic `HTTPRequest`/`HTTPResponse` pair.
///
/// Deliberately not a general web server:
/// - listens on the loopback interface only — never on a routable address
/// - one request per connection (`Connection: close`), no keep-alive
/// - `Content-Length` bodies only, no chunked transfer encoding
/// - anything the MCP transport doesn't accept comes back as its 4xx/5xx
///
/// Request parsing and response serialization are pure static functions so unit
/// tests can exercise them without opening sockets.
actor MCPHTTPListener {
  typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

  enum ListenerError: Error, Equatable {
    case failedToStart(String)
    case alreadyRunning
  }

  /// Caps chosen so a full-scrollback read fits comfortably while a runaway
  /// local client can't balloon memory: 16 KB of headers, 4 MB of body.
  static let maxHeaderBytes = 16 * 1024
  static let maxBodyBytes = 4 * 1024 * 1024
  /// A connection that hasn't produced a complete request/response cycle by
  /// this deadline is cancelled — protects against stuck local clients.
  static let connectionDeadline: Duration = .seconds(60)

  private let port: UInt16
  private let handler: Handler
  private let queue = DispatchQueue(label: "io.morethan.supacool.mcp-http")
  private var listener: NWListener?

  init(port: UInt16, handler: @escaping Handler) {
    self.port = port
    self.handler = handler
  }

  /// Starts listening on `127.0.0.1:port`. Throws if the port is taken or the
  /// listener fails to become ready.
  func start() async throws {
    guard listener == nil else { throw ListenerError.alreadyRunning }
    guard let nwPort = NWEndpoint.Port(rawValue: port) else {
      throw ListenerError.failedToStart("invalid port \(port)")
    }
    let parameters = NWParameters.tcp
    // Loopback-only: never expose the control plane on a routable interface.
    // Phase 3 (Tailscale) fronts this with its own tunnel instead of widening the bind.
    parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)
    parameters.allowLocalEndpointReuse = true
    let listener = try NWListener(using: parameters)

    listener.newConnectionHandler = { [weak self] connection in
      guard let self else {
        connection.cancel()
        return
      }
      Task { await self.serve(connection) }
    }

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      // Ready/failed both race to resume; nil-out the handler after first fire.
      nonisolated(unsafe) var pending: CheckedContinuation<Void, Error>? = continuation
      listener.stateUpdateHandler = { state in
        switch state {
        case .ready:
          pending?.resume()
          pending = nil
        case .failed(let error):
          pending?.resume(throwing: ListenerError.failedToStart(error.localizedDescription))
          pending = nil
        case .cancelled:
          pending?.resume(throwing: ListenerError.failedToStart("listener cancelled during startup"))
          pending = nil
        default:
          break
        }
      }
      listener.start(queue: queue)
    }

    listener.stateUpdateHandler = { state in
      if case .failed(let error) = state {
        listenerLogger.warning("listener failed after start: \(error.localizedDescription)")
      }
    }
    self.listener = listener
    listenerLogger.info("listening on 127.0.0.1:\(port)")
  }

  func stop() {
    listener?.cancel()
    listener = nil
  }

  // MARK: - Connection lifecycle

  private func serve(_ connection: NWConnection) async {
    connection.start(queue: queue)
    defer { connection.cancel() }

    let deadline = Task {
      try await Task.sleep(for: Self.connectionDeadline)
      connection.cancel()
    }
    defer { deadline.cancel() }

    do {
      let request = try await Self.readRequest(from: connection)
      let response = await handler(request)
      try await Self.send(Self.serialize(response), over: connection)
    } catch let failure as RequestFailure {
      let body = Data(failure.message.utf8)
      try? await Self.send(
        Self.serializeRaw(statusCode: failure.statusCode, headers: [:], body: body),
        over: connection
      )
    } catch {
      // Read/write errors on a dying connection — nothing useful to answer.
      listenerLogger.debug("connection dropped: \(error.localizedDescription)")
    }
  }

  private struct RequestFailure: Error {
    let statusCode: Int
    let message: String
  }

  private static func readRequest(from connection: NWConnection) async throws -> HTTPRequest {
    var buffer = Data()

    // Accumulate until the header terminator, then until Content-Length is satisfied.
    while true {
      if let headerEnd = headerEndIndex(in: buffer) {
        guard let head = parseHead(buffer.prefix(headerEnd)) else {
          throw RequestFailure(statusCode: 400, message: "malformed request head")
        }
        let bodyStart = headerEnd + 4
        let contentLength = declaredContentLength(in: head.headers)
        guard contentLength <= maxBodyBytes else {
          throw RequestFailure(statusCode: 413, message: "body too large")
        }
        if buffer.count - bodyStart >= contentLength {
          let body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
          return HTTPRequest(
            method: head.method,
            headers: head.headers,
            body: body.isEmpty ? nil : body,
            path: head.path
          )
        }
      } else if buffer.count > maxHeaderBytes {
        throw RequestFailure(statusCode: 431, message: "headers too large")
      }

      let chunk = try await receiveChunk(from: connection)
      guard !chunk.isEmpty else {
        throw RequestFailure(statusCode: 400, message: "connection closed mid-request")
      }
      buffer.append(chunk)
    }
  }

  private static func receiveChunk(from connection: NWConnection) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
        data, _, isComplete, error in
        if let error {
          continuation.resume(throwing: error)
        } else if let data, !data.isEmpty {
          continuation.resume(returning: data)
        } else if isComplete {
          continuation.resume(returning: Data())
        } else {
          continuation.resume(returning: Data())
        }
      }
    }
  }

  private static func send(_ data: Data, over connection: NWConnection) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      connection.send(
        content: data,
        completion: .contentProcessed { error in
          if let error {
            continuation.resume(throwing: error)
          } else {
            continuation.resume()
          }
        }
      )
    }
  }

  // MARK: - Parsing (pure, unit-testable)

  /// Index of the first byte of the `\r\n\r\n` header terminator, or nil.
  static func headerEndIndex(in data: Data) -> Int? {
    guard let range = data.firstRange(of: Data("\r\n\r\n".utf8)) else { return nil }
    return range.lowerBound
  }

  /// Parses the request line and headers. Returns nil on anything malformed.
  static func parseHead(_ data: Data) -> (method: String, path: String, headers: [String: String])? {
    guard let head = String(data: data, encoding: .utf8) else { return nil }
    var lines = head.split(separator: "\r\n", omittingEmptySubsequences: false)[...]
    guard let requestLine = lines.popFirst() else { return nil }
    let parts = requestLine.split(separator: " ")
    guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return nil }
    let method = String(parts[0])
    let path = String(parts[1])

    var headers: [String: String] = [:]
    for line in lines where !line.isEmpty {
      guard let colon = line.firstIndex(of: ":") else { return nil }
      let name = line[..<colon].trimmingCharacters(in: .whitespaces)
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      guard !name.isEmpty else { return nil }
      headers[name] = value
    }
    return (method, path, headers)
  }

  static func declaredContentLength(in headers: [String: String]) -> Int {
    let value = headers.first { $0.key.lowercased() == "content-length" }?.value
    return value.flatMap(Int.init) ?? 0
  }

  // MARK: - Serialization (pure, unit-testable)

  static func serialize(_ response: HTTPResponse) -> Data {
    // `.stream` never occurs with the stateless transport; answer with an
    // empty body rather than pretending to speak SSE.
    serializeRaw(
      statusCode: response.statusCode,
      headers: response.headers,
      body: response.bodyData ?? Data()
    )
  }

  static func serializeRaw(statusCode: Int, headers: [String: String], body: Data) -> Data {
    var head = "HTTP/1.1 \(statusCode) \(reasonPhrase(for: statusCode))\r\n"
    var allHeaders = headers
    allHeaders["Content-Length"] = String(body.count)
    allHeaders["Connection"] = "close"
    for (name, value) in allHeaders.sorted(by: { $0.key < $1.key }) {
      head += "\(name): \(value)\r\n"
    }
    head += "\r\n"
    var data = Data(head.utf8)
    data.append(body)
    return data
  }

  static func reasonPhrase(for statusCode: Int) -> String {
    switch statusCode {
    case 200: "OK"
    case 202: "Accepted"
    case 400: "Bad Request"
    case 401: "Unauthorized"
    case 403: "Forbidden"
    case 404: "Not Found"
    case 405: "Method Not Allowed"
    case 413: "Payload Too Large"
    case 421: "Misdirected Request"
    case 431: "Request Header Fields Too Large"
    case 500: "Internal Server Error"
    default: "Status \(statusCode)"
    }
  }
}
