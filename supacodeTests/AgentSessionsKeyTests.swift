import Dependencies
import Foundation
import Testing

@testable import Supacool

/// `@Shared(.agentSessions)` is deduped by `AgentSessionsKey.id`. Production
/// resolves one constant sessions directory, so the whole app shares a single
/// box; tests inject a unique temp directory per dependency context, so each
/// `@Test` must resolve an ISOLATED box. Without this, concurrently-running
/// Swift Testing tests share one global box and pollute each other — the flaky
/// board/bookmark/PR-pulse CI failures. These tests pin the dedup contract
/// deterministically (no reliance on the parallel race reproducing).
@Suite struct AgentSessionsKeyTests {
  private func locations(_ tag: String) -> SessionStorageLocations {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "agentsessions-\(tag)-\(UUID().uuidString)", directoryHint: .isDirectory)
    return SessionStorageLocations(
      directory: root.appending(path: "sessions", directoryHint: .isDirectory)
    )
  }

  @Test func idIsScopedToTheInjectedDirectory() {
    let idA = withDependencies { $0.sessionStorageLocations = locations("A") } operation: {
      AgentSessionsKey().id
    }
    let idB = withDependencies { $0.sessionStorageLocations = locations("B") } operation: {
      AgentSessionsKey().id
    }
    #expect(idA != idB)
  }

  @Test func idIsStableForTheSameDirectory() {
    let location = locations("stable")
    let first = withDependencies { $0.sessionStorageLocations = location } operation: {
      AgentSessionsKey().id
    }
    let second = withDependencies { $0.sessionStorageLocations = location } operation: {
      AgentSessionsKey().id
    }
    #expect(first == second)
  }
}
