import Foundation
import SwiftUI

enum BoardSessionStatus: Equatable, Sendable {
  case inProgress
  case waitingOnMe
  case awaitingInput
  case detached
  case interrupted
  case fresh
  case parked

  static let initialLaunchGrace: TimeInterval = 3
  static let idleRebucketDelay: TimeInterval = 1.2

  var label: String {
    switch self {
    case .inProgress: "Working"
    case .waitingOnMe: "Waiting"
    case .awaitingInput: "Wants Input"
    case .detached: "Idle"
    case .interrupted: "Interrupted"
    case .fresh: "Starting"
    case .parked: "Parked"
    }
  }

  var color: Color {
    switch self {
    case .inProgress: .green
    case .waitingOnMe: .orange
    case .awaitingInput: .orange
    case .detached: .secondary
    case .interrupted: .yellow
    case .fresh: .blue
    case .parked: .secondary
    }
  }

  var systemImage: String {
    switch self {
    case .inProgress: "circle.fill"
    case .waitingOnMe: "exclamationmark.circle.fill"
    case .awaitingInput: "hand.raised.fill"
    case .detached: "moon.zzz.fill"
    case .interrupted: "exclamationmark.triangle.fill"
    case .fresh: "sparkles"
    case .parked: "parkingsign"
    }
  }

  static func classify(
    session: AgentSession,
    tabExists: Bool,
    awaitingInput: Bool,
    busy: Bool,
    now: Date = Date()
  ) -> Self {
    if session.parked {
      return .parked
    }
    if !tabExists {
      return session.lastKnownBusy ? .interrupted : .detached
    }
    if awaitingInput {
      return .awaitingInput
    }
    if busy {
      return .inProgress
    }
    if shouldKeepInProgressWhileIdle(session: session, now: now) {
      return session.hasCompletedAtLeastOnce ? .inProgress : .fresh
    }
    if !session.hasCompletedAtLeastOnce,
      now.timeIntervalSince(session.createdAt) < initialLaunchGrace
    {
      return .fresh
    }
    return .waitingOnMe
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
