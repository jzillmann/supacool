import Foundation

/// Something a workspace's server lifecycle script reported as listening.
///
/// These are *parsed out of the script's own stdout* rather than configured,
/// so no repo has to teach Supacool about its ports — see `ServerEndpointScanner`.
nonisolated struct ServerEndpoint: Equatable, Hashable, Sendable, Identifiable {
  let scheme: String
  let host: String
  let port: Int
  /// True when the script printed a whole URL, false when we inferred the
  /// endpoint from a bare `:port`. A declared URL always outranks an inferred
  /// one — see `ServerEndpointScanner.primary(of:)`.
  let isDeclared: Bool

  init(scheme: String = "http", host: String = "localhost", port: Int, isDeclared: Bool = false) {
    self.scheme = scheme
    self.host = host
    self.port = port
    self.isDeclared = isDeclared
  }

  var id: String { "\(host):\(port)" }

  var url: URL? { URL(string: "\(scheme)://\(host):\(port)") }

  /// Chip label. Local endpoints collapse to `:3606` because the host carries
  /// no information; anything else keeps its host so the link is unambiguous.
  var label: String {
    Self.localHosts.contains(host) ? ":\(port)" : "\(host):\(port)"
  }

  private static let localHosts: Set<String> = ["localhost", "127.0.0.1", "0.0.0.0", "::1"]
}

/// Finds the endpoints in a lifecycle script's output and picks the one worth
/// putting behind the board chip's link.
///
/// The hard part is not finding ports, it's choosing among them: a `dev status`
/// that prints a whole fleet (frontend, backend, two databases) offers no
/// positional clue about which one a human wants to open. So we rank instead of
/// guess blindly, and surface the full list when the ranking has no opinion.
nonisolated enum ServerEndpointScanner {
  /// Ports below this are almost never a dev server, and skipping them is what
  /// keeps the bare-`:port` pattern from reading clock times as endpoints
  /// (`10:30:00` would otherwise yield `:30` and `:00`).
  private static let lowestInferredPort = 1024
  private static let highestPort = 65535

  /// Ports a human plausibly opens in a browser. Deliberately small and boring —
  /// it only has to break a tie, and everything it misses still reaches the user
  /// through the full endpoint list.
  private static let webPortRange = 3000...3999
  private static let webPorts: Set<Int> = [4000, 4200, 5173, 5174, 8000, 8080]

  // Computed, not stored: `Regex` is not Sendable, so a `static let` here is a
  // Swift 6 concurrency error. Building one per scan is cheap next to the
  // subprocess that produced the output.
  private static var urlPattern: Regex<Substring> { /https?:\/\/[^\s"'<>,)\]]+/ }
  private static var barePortPattern: Regex<(Substring, Substring)> { /:(\d{2,5})\b/ }

  /// Every endpoint mentioned in `output`, in order of first appearance and
  /// deduped by `host:port`.
  static func scan(_ output: String) -> [ServerEndpoint] {
    var found: [(offset: Int, endpoint: ServerEndpoint)] = []
    var declaredRanges: [Range<String.Index>] = []

    for match in output.matches(of: urlPattern) {
      guard let endpoint = declaredEndpoint(from: String(match.output)) else { continue }
      declaredRanges.append(match.range)
      found.append((output.distance(from: output.startIndex, to: match.range.lowerBound), endpoint))
    }

    for match in output.matches(of: barePortPattern) {
      // A URL's own `:3606` already produced a richer, declared endpoint.
      guard !declaredRanges.contains(where: { $0.overlaps(match.range) }) else { continue }
      guard let port = Int(match.output.1), (lowestInferredPort...highestPort).contains(port) else { continue }
      found.append(
        (
          output.distance(from: output.startIndex, to: match.range.lowerBound),
          ServerEndpoint(port: port)
        )
      )
    }

    found.sort { $0.offset < $1.offset }
    var seen: Set<String> = []
    return found.map(\.endpoint).filter { seen.insert($0.id).inserted }
  }

  /// The one endpoint to hang the chip's link on, or nil when the output is too
  /// ambiguous to call and the user should pick from the full list.
  static func primary(of endpoints: [ServerEndpoint]) -> ServerEndpoint? {
    if let declared = endpoints.first(where: \.isDeclared) { return declared }
    if let webLike = endpoints.first(where: { isWebLike($0.port) }) { return webLike }
    // A lone endpoint is unambiguous even when it looks nothing like a web port:
    // a script reporting only `:9000` is still reporting the thing to open.
    if endpoints.count == 1 { return endpoints.first }
    return nil
  }

  private static func isWebLike(_ port: Int) -> Bool {
    webPortRange.contains(port) || webPorts.contains(port)
  }

  private static func declaredEndpoint(from text: String) -> ServerEndpoint? {
    let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
    guard let components = URLComponents(string: trimmed),
      let scheme = components.scheme,
      let host = components.host,
      !host.isEmpty
    else {
      return nil
    }
    let port = components.port ?? (scheme == "https" ? 443 : 80)
    guard (1...highestPort).contains(port) else { return nil }
    return ServerEndpoint(scheme: scheme, host: host, port: port, isDeclared: true)
  }
}
