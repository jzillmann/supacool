import Foundation
import Testing

@testable import Supacool

struct ServerEndpointScannerTests {
  /// Verbatim `dev status` output (ANSI already stripped by the lifecycle
  /// client): five ports, of which only the frontend is worth opening.
  private static let devStatusOutput = """
    Service Status
      ✓ pyomo-service  :8688  running (PID 7934, healthy)
        log: logs/pyomo-service.log
      ✓ backend        :8686  running (PID 7974, healthy)
        log: logs/backend.log
      ✓ frontend       :3606  running (PID 8225, healthy)
        log: logs/frontend.log

    ! 8 stale PID file(s) — run `dev stop --orphans` to clean up

    SAP Containers (Docker)
      ✓ sap-us         :5433  running (Docker)
      ✓ sap-de         :5434  running (Docker)
    """

  @Test func scanFindsEveryPortInFirstAppearanceOrder() {
    let endpoints = ServerEndpointScanner.scan(Self.devStatusOutput)

    #expect(endpoints.map(\.port) == [8688, 8686, 3606, 5433, 5434])
    #expect(endpoints.allSatisfy { $0.host == "localhost" && $0.scheme == "http" })
    #expect(endpoints.allSatisfy { !$0.isDeclared })
  }

  @Test func primaryPicksTheWebLikePortOutOfAFleet() {
    let primary = ServerEndpointScanner.primary(of: ServerEndpointScanner.scan(Self.devStatusOutput))

    #expect(primary?.port == 3606)
    #expect(primary?.url?.absoluteString == "http://localhost:3606")
    #expect(primary?.label == ":3606")
  }

  @Test func scanReadsPortsOutOfDevStartProgressOutput() {
    let output = """
      Starting services
      [1/3] Starting pyomo-service on :8688
      • pyomo-service started (PID 80753)
      [2/3] Starting backend on :8686
      [3/3] Starting frontend on :3606
      ✓ Dev servers running
      """

    let endpoints = ServerEndpointScanner.scan(output)

    // `[1/3]` and the PIDs must not read as ports.
    #expect(endpoints.map(\.port) == [8688, 8686, 3606])
    #expect(ServerEndpointScanner.primary(of: endpoints)?.port == 3606)
  }

  @Test func declaredURLOutranksABareWebPort() {
    let endpoints = ServerEndpointScanner.scan("ui on :3000\nadmin at https://admin.test:9443/panel")

    // scan() reports first-appearance order; only primary() ranks.
    #expect(endpoints.map(\.port) == [3000, 9443])
    let primary = ServerEndpointScanner.primary(of: endpoints)
    #expect(primary?.port == 9443)
    #expect(primary?.isDeclared == true)
    #expect(primary?.label == "admin.test:9443")
  }

  @Test func declaredURLDoesNotAlsoYieldABarePortForItsOwnColon() {
    let endpoints = ServerEndpointScanner.scan("listening on http://localhost:4321/")

    #expect(endpoints.count == 1)
    #expect(endpoints.first?.port == 4321)
    #expect(endpoints.first?.isDeclared == true)
  }

  @Test func urlWithoutAnExplicitPortFallsBackToTheSchemeDefault() {
    let endpoints = ServerEndpointScanner.scan("proxied at https://preview.test/app")

    #expect(endpoints.map(\.port) == [443])
    #expect(endpoints.first?.label == "preview.test:443")
  }

  // The gap in the pure web-port heuristic: a repo whose only server is on an
  // unremarkable port still deserves a link, because there is nothing to
  // confuse it with.
  @Test func loneNonWebPortIsStillPrimary() {
    let endpoints = ServerEndpointScanner.scan("api listening on :9000")

    #expect(endpoints.map(\.port) == [9000])
    #expect(ServerEndpointScanner.primary(of: endpoints)?.port == 9000)
  }

  @Test func severalNonWebPortsRefuseToGuess() {
    let endpoints = ServerEndpointScanner.scan("api :9000\nqueue :9100")

    #expect(endpoints.map(\.port) == [9000, 9100])
    #expect(ServerEndpointScanner.primary(of: endpoints) == nil)
  }

  @Test func clockTimesAndLowPortsAreNotEndpoints() {
    let endpoints = ServerEndpointScanner.scan("started at 10:30:00, uptime 0:05, pid 812")

    #expect(endpoints.isEmpty)
  }

  @Test func repeatedPortsCollapse() {
    let endpoints = ServerEndpointScanner.scan("frontend :3606 healthy\nfrontend :3606 ready")

    #expect(endpoints.map(\.port) == [3606])
  }

  @Test func emptyOutputYieldsNothing() {
    #expect(ServerEndpointScanner.scan("").isEmpty)
    #expect(ServerEndpointScanner.primary(of: []) == nil)
  }
}
