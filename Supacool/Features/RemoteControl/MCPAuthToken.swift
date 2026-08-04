import Foundation
import MCP

/// The shared secret gating the remote-control MCP endpoint.
///
/// Lives at `~/.supacool/mcp-token` with owner-only permissions — consistent
/// with the app's file-based storage (no Keychain precedent in the codebase).
/// Localhost-only exposure makes this acceptable for Phase 1; revisit before
/// any off-machine exposure (Phase 3).
nonisolated enum MCPAuthToken {
  static func tokenURL(in directory: URL = SupacoolPaths.baseDirectory) -> URL {
    directory.appending(path: "mcp-token", directoryHint: .notDirectory)
  }

  /// Returns the existing token, generating (and persisting) one if absent.
  static func loadOrCreate(in directory: URL = SupacoolPaths.baseDirectory) throws -> String {
    if let existing = try? String(contentsOf: tokenURL(in: directory), encoding: .utf8) {
      let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty { return trimmed }
    }
    return try regenerate(in: directory)
  }

  /// Mints a fresh token, replacing any existing one. Existing clients must
  /// be reconfigured afterwards.
  @discardableResult
  static func regenerate(in directory: URL = SupacoolPaths.baseDirectory) throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw CocoaError(.fileWriteUnknown)
    }
    let token = bytes.map { String(format: "%02x", $0) }.joined()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = tokenURL(in: directory)
    try Data(token.utf8).write(to: url, options: [.atomic])
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: url.path
    )
    return token
  }

  /// Constant-time equality so request handling doesn't leak the token via
  /// comparison timing. Both operands are visible to any local process able
  /// to read the token file anyway, but cheap to do right.
  static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
    let lhsBytes = Array(lhs.utf8)
    let rhsBytes = Array(rhs.utf8)
    guard lhsBytes.count == rhsBytes.count else { return false }
    var difference: UInt8 = 0
    for (l, r) in zip(lhsBytes, rhsBytes) {
      difference |= l ^ r
    }
    return difference == 0
  }
}

/// Static-secret bearer check for the localhost control plane.
///
/// Deliberately simpler than the SDK's OAuth-shaped `BearerTokenValidator`:
/// no resource metadata, no scopes — just `Authorization: Bearer <secret>`
/// compared in constant time, 401 with a plain challenge otherwise.
nonisolated struct StaticBearerValidator: HTTPRequestValidator {
  let secret: String

  func validate(_ request: HTTPRequest, context: HTTPValidationContext) -> HTTPResponse? {
    guard let authorization = request.header(HTTPHeaderName.authorization) else {
      return .error(
        statusCode: 401,
        .invalidRequest("Unauthorized: missing bearer token"),
        extraHeaders: [HTTPHeaderName.wwwAuthenticate: "Bearer"]
      )
    }
    let prefix = "Bearer "
    guard authorization.hasPrefix(prefix),
      MCPAuthToken.constantTimeEquals(String(authorization.dropFirst(prefix.count)), secret)
    else {
      return .error(
        statusCode: 401,
        .invalidRequest("Unauthorized: invalid bearer token"),
        extraHeaders: [HTTPHeaderName.wwwAuthenticate: "Bearer error=\"invalid_token\""]
      )
    }
    return nil
  }
}
