import Foundation

/// Shared resume eligibility/routing for board cards. Kept outside the
/// SwiftUI view so the multi-select behavior stays testable.
nonisolated enum BoardResumeEligibility {
  static func hasCapturedNativeSessionID(_ session: AgentSession) -> Bool {
    guard let sessionID = session.agentNativeSessionID else { return false }
    return !sessionID.isEmpty
  }

  static func canDirectResume(
    _ session: AgentSession,
    status: BoardSessionStatus,
    tabExists: Bool = false,
    includingParked: Bool = false
  ) -> Bool {
    guard let agent = session.agent,
      hasCapturedNativeSessionID(session),
      agent.resumeCommand(sessionID: "placeholder") != nil
    else {
      return false
    }

    switch status {
    case .detached, .interrupted:
      return true
    case .parked:
      return includingParked && !tabExists
    default:
      return false
    }
  }

  static func canResumeWithPicker(
    _ session: AgentSession,
    status: BoardSessionStatus,
    tabExists: Bool = false,
    includingParked: Bool = false
  ) -> Bool {
    guard let agent = session.agent,
      !hasCapturedNativeSessionID(session),
      agent.resumePickerCommand() != nil
    else {
      return false
    }

    switch status {
    case .detached, .interrupted:
      return true
    case .parked:
      return includingParked && !tabExists
    default:
      return false
    }
  }

  static func selectedResumeRoutes(
    sessions: [AgentSession],
    selectedIDs: Set<AgentSession.ID>,
    classify: (AgentSession) -> BoardSessionStatus,
    tabExists: (AgentSession) -> Bool
  ) -> [BoardSelectedResumeRoute] {
    guard selectedIDs.count > 1 else { return [] }

    return sessions.compactMap { session in
      guard selectedIDs.contains(session.id) else { return nil }

      let status = classify(session)
      let hasTab = tabExists(session)
      if canDirectResume(session, status: status, tabExists: hasTab, includingParked: true) {
        return .direct(session.id)
      }
      if canResumeWithPicker(session, status: status, tabExists: hasTab, includingParked: true) {
        return .picker(session.id)
      }
      return nil
    }
  }
}

nonisolated enum BoardSelectedResumeRoute: Equatable, Sendable {
  case direct(AgentSession.ID)
  case picker(AgentSession.ID)

  var id: AgentSession.ID {
    switch self {
    case .direct(let id), .picker(let id): id
    }
  }

  var usesPicker: Bool {
    switch self {
    case .direct: false
    case .picker: true
    }
  }
}
