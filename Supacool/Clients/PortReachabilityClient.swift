import ComposableArchitecture
import Foundation
import Network

/// Answers the one question the board's server chip needs and a `dev status`
/// script routinely lies about: is something actually listening on this port?
///
/// A repo's status command is a *reporting* command — it prints its whole fleet
/// and exits 0 whether or not anything is up. Trusting that exit code lit the
/// chip green over a stone-dead server. So we stop trusting it: we open a TCP
/// connection to the ports the status output named, and a refused or timed-out
/// connect is the ground truth that the server is down.
nonisolated struct PortReachabilityClient: Sendable {
  /// True when a TCP connection to `host:port` completes before the client's
  /// internal timeout. A connection refused (nothing listening) resolves to
  /// false quickly; only a filtered/unroutable port waits out the timeout.
  var isReachable: @Sendable (_ host: String, _ port: Int) async -> Bool
}

extension PortReachabilityClient: DependencyKey {
  static let liveValue = PortReachabilityClient { host, port in
    await tcpConnectSucceeds(host: host, port: port, timeout: .milliseconds(1200))
  }

  /// Nothing is reachable in tests unless a case overrides it, so the board's
  /// status logic stays deterministic without ever touching the network.
  static let testValue = PortReachabilityClient { _, _ in false }
}

extension DependencyValues {
  var portReachabilityClient: PortReachabilityClient {
    get { self[PortReachabilityClient.self] }
    set { self[PortReachabilityClient.self] = newValue }
  }
}

private nonisolated func tcpConnectSucceeds(
  host: String,
  port: Int,
  timeout: Duration
) async -> Bool {
  guard let rawPort = UInt16(exactly: port), let nwPort = NWEndpoint.Port(rawValue: rawPort) else {
    return false
  }
  let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)

  return await withTaskGroup(of: Bool.self) { group in
    group.addTask {
      await withTaskCancellationHandler {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
          let resumed = LockIsolated(false)
          let finish: @Sendable (Bool) -> Void = { reachable in
            let isFirst = resumed.withValue { done -> Bool in
              guard !done else { return false }
              done = true
              return true
            }
            guard isFirst else { return }
            continuation.resume(returning: reachable)
          }
          connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
              finish(true)
            case .waiting, .failed, .cancelled:
              // `.waiting` is where a refused/unroutable connect lands — Network
              // treats it as retriable, but for us it means "not up right now".
              finish(false)
            default:
              break
            }
          }
          connection.start(queue: .global())
        }
      } onCancel: {
        connection.cancel()
      }
    }
    group.addTask {
      try? await Task.sleep(for: timeout)
      return false
    }
    let reachable = await group.next() ?? false
    group.cancelAll()
    connection.cancel()
    return reachable
  }
}
