import ComposableArchitecture
import Foundation
import Observation
import SwiftUI

/// Global store that holds the most recent `ProcessFootprintSnapshot`
/// and polls it on a shared cadence. One sampler shared across the
/// toolbar chip and every session card — so we don't run N × `ps`
/// invocations per tick when the board has many cards.
///
/// The store is deliberately tiny: it holds the snapshot, exposes a
/// bytes-for-session lookup, and the chip/cards read it via
/// `@Environment`. The poll loop is owned by the top-level chip so
/// views don't race to start the loop.
@MainActor
@Observable
final class SessionFootprintStore {
  /// Latest snapshot, or nil until the first sample lands.
  private(set) var snapshot: ProcessFootprintSnapshot?
  /// True while a sample is in flight. Exposed so the sheet can show
  /// a progress indicator when the user hits Refresh.
  private(set) var isRefreshing: Bool = false

  @ObservationIgnored private let sample:
    @Sendable (Int32, [SessionAnchor]) async throws -> ProcessFootprintSnapshot
  @ObservationIgnored private var anchorProvider: () -> [SessionAnchor] = { [] }

  init(sample: @escaping @Sendable (Int32, [SessionAnchor]) async throws -> ProcessFootprintSnapshot) {
    self.sample = sample
  }

  /// The anchor provider must be wired before `refresh()` produces per-
  /// session attribution. Callers should set it from the board view,
  /// re-pointing the closure at `store.sessions` so the latest set is
  /// always sampled.
  func setAnchorProvider(_ provider: @escaping () -> [SessionAnchor]) {
    self.anchorProvider = provider
  }

  /// Returns the aggregate bytes attributed to a given session id, or
  /// nil when the session has no sampled footprint yet (surface hasn't
  /// spawned, or no snapshot taken).
  func bytes(for sessionID: UUID) -> UInt64? {
    snapshot?.sessionFootprints[sessionID]?.aggregatedBytes
  }

  /// Full per-session footprint for tooltip/analysis use.
  func footprint(for sessionID: UUID) -> ProcessFootprintSnapshot.SessionFootprint? {
    snapshot?.sessionFootprints[sessionID]
  }

  func refresh() async {
    isRefreshing = true
    defer { isRefreshing = false }
    do {
      let anchors = anchorProvider()
      let newShot = try await sample(ProcessInfo.processInfo.processIdentifier, anchors)
      snapshot = newShot
    } catch {
      // Swallow — the chip falls back to showing the last known value.
    }
  }
}

/// Environment key so the board can hand the shared
/// `SessionFootprintStore` down to individual cards without threading
/// it through every intermediate view's init.
private struct SessionFootprintStoreKey: EnvironmentKey {
  static let defaultValue: SessionFootprintStore? = nil
}

extension EnvironmentValues {
  var sessionFootprintStore: SessionFootprintStore? {
    get { self[SessionFootprintStoreKey.self] }
    set { self[SessionFootprintStoreKey.self] = newValue }
  }
}
