import Foundation
import SwiftUI

nonisolated enum BoardSessionStatus: String, Equatable, Sendable, Codable {
  case inProgress
  /// Card is idle because an external process owns the next move — most
  /// often a PR is mid-CI or awaiting review. Historical raw value kept as
  /// `waitingForChecks` for codable stability; UI label is "Waiting on
  /// External". Can also be pinned manually via the card context menu.
  case waitingForChecks
  case waitingOnMe
  case awaitingInput
  case detached
  case interrupted
  case fresh
  case parked
  /// SSH link dropped for a remote session — the remote tmux almost
  /// certainly survived, but the ssh tab's PTY is gone. User clicks
  /// Reconnect to re-spawn ssh and `tmux attach`.
  case disconnected

  static let missingInitialAgentEventGrace: TimeInterval = 30
  static let idleRebucketDelay: TimeInterval = 1.2

  var label: String {
    switch self {
    case .inProgress: "Working"
    case .waitingForChecks: "Waiting on External"
    case .waitingOnMe: "Waiting"
    case .awaitingInput: "Wants Input"
    case .detached: "Idle"
    case .interrupted: "Interrupted"
    case .fresh: "Starting"
    case .parked: "Parked"
    case .disconnected: "Disconnected"
    }
  }

  var color: Color {
    switch self {
    case .inProgress: .green
    case .waitingForChecks: .blue
    case .waitingOnMe: .orange
    case .awaitingInput: .orange
    case .detached: .secondary
    case .interrupted: .yellow
    case .fresh: .blue
    case .parked: .secondary
    case .disconnected: .red
    }
  }

  var systemImage: String {
    switch self {
    case .inProgress: "circle.fill"
    case .waitingForChecks: "hourglass.circle.fill"
    case .waitingOnMe: "exclamationmark.circle.fill"
    case .awaitingInput: "hand.raised.fill"
    case .detached: "moon.zzz.fill"
    case .interrupted: "exclamationmark.triangle.fill"
    case .fresh: "sparkles"
    case .parked: "parkingsign"
    case .disconnected: "bolt.slash.fill"
    }
  }

  static func classify(
    session: AgentSession,
    tabExists: Bool,
    awaitingInput: Bool,
    busy: Bool,
    deferredWork: Bool = false,
    waitingExternally: Bool = false,
    now: Date = Date()
  ) -> Self {
    if session.parked {
      return .parked
    }
    if !tabExists {
      // Remote sessions model "tab gone" differently: the ssh link
      // dropped, but tmux on the remote almost always survives.
      // `.disconnected` drives the Reconnect overlay.
      if session.isRemote {
        return .disconnected
      }
      return session.lastKnownBusy ? .interrupted : .detached
    }
    // Manual override wins over auto-classification while the tab is
    // alive. The reducer auto-clears it on the next busy-state transition,
    // so a real hook signal will always retake control.
    if let override = session.manualStatusOverride {
      return override
    }
    if awaitingInput {
      return .awaitingInput
    }
    if busy || deferredWork {
      return .inProgress
    }
    if shouldKeepInProgressWhileIdle(session: session, now: now) {
      return session.hasCompletedAtLeastOnce ? .inProgress : .fresh
    }
    if !session.hasCompletedAtLeastOnce {
      if session.agent != nil, !session.hasObservedInitialAgentEvent {
        return now.timeIntervalSince(session.createdAt) < missingInitialAgentEventGrace
          ? .fresh
          : .waitingOnMe
      }
      if session.agent == nil, now.timeIntervalSince(session.createdAt) < missingInitialAgentEventGrace {
        return .fresh
      }
    }
    return waitingExternally ? .waitingForChecks : .waitingOnMe
  }

  private static func shouldKeepInProgressWhileIdle(
    session: AgentSession,
    now: Date
  ) -> Bool {
    guard !session.lastKnownBusy else { return false }
    guard let lastBusyTransitionAt = session.lastBusyTransitionAt else { return false }
    return now.timeIntervalSince(lastBusyTransitionAt) < idleRebucketDelay
  }
}
