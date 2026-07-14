import Foundation
import Testing

@testable import Supacool

/// Verifies the legacy → composition migration on `AgentSession.init(from:)`
/// and the forward-compatibility convention for the new `terminals` shape.
@MainActor
struct AgentSessionMigrationTests {

  // MARK: Legacy schema migration

  @Test func legacyJSONMigratesIntoSingleTerminal() throws {
    // A snapshot of the OLD on-disk shape — pre-composition. The decoder
    // must synthesize a single .agent terminal from these flat fields.
    let sessionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let lastBusy = Date(timeIntervalSince1970: 1_750_000_000)
    let json = """
    {
      "id": "\(sessionID.uuidString)",
      "repositoryID": "/tmp/repo",
      "worktreeID": "/tmp/repo",
      "currentWorkspacePath": "/tmp/repo",
      "displayName": "Test prompt",
      "agent": "claude",
      "initialPrompt": "Test prompt",
      "agentNativeSessionID": "claude-abc-123",
      "createdAt": 1750000000,
      "lastActivityAt": 1750000050,
      "hasCompletedAtLeastOnce": true,
      "hasObservedInitialAgentEvent": true,
      "lastKnownBusy": true,
      "lastBusyTransitionAt": \(lastBusy.timeIntervalSinceReferenceDate - Date.timeIntervalBetween1970AndReferenceDate),
      "isPriority": false,
      "planMode": false,
      "parked": false,
      "autoObserver": false,
      "autoObserverPrompt": "",
      "references": [],
      "remoteConnectionLost": false,
      "removeBackingWorktreeOnDelete": false
    }
    """
    let session = try JSONDecoder().decode(AgentSession.self, from: Data(json.utf8))

    // Session-level fields migrated as-is.
    #expect(session.id == sessionID)
    #expect(session.repositoryID == "/tmp/repo")
    #expect(session.worktreeID == "/tmp/repo")
    #expect(session.displayName == "Test prompt")

    // Composition: exactly one terminal, primaryTerminalID == session.id.
    #expect(session.terminals.count == 1)
    #expect(session.primaryTerminalID == sessionID)
    let primary = session.primaryTerminal
    #expect(primary.id == sessionID)
    #expect(primary.role == .agent)
    #expect(primary.agent == .claude)
    #expect(primary.initialPrompt == "Test prompt")
    #expect(primary.agentNativeSessionID == "claude-abc-123")
    #expect(primary.hasCompletedAtLeastOnce == true)
    #expect(primary.hasObservedInitialAgentEvent == true)
    #expect(primary.lastKnownBusy == true)

    // Read-only forwarders agree with the primary terminal.
    #expect(session.agent == .claude)
    #expect(session.initialPrompt == "Test prompt")
    #expect(session.agentNativeSessionID == "claude-abc-123")
    #expect(session.lastKnownBusy == true)
  }

  @Test func legacyShellSessionMigratesAsShellTerminal() throws {
    // Legacy raw-shell sessions had `agent: null`. They should land as
    // `.shell` role with no agent — not as `.agent` with nil agent.
    let json = """
    {
      "id": "22222222-2222-2222-2222-222222222222",
      "repositoryID": "/tmp/repo",
      "worktreeID": "/tmp/repo",
      "currentWorkspacePath": "/tmp/repo",
      "displayName": "ls -la",
      "initialPrompt": "ls -la",
      "createdAt": 1750000000,
      "lastActivityAt": 1750000050,
      "removeBackingWorktreeOnDelete": false,
      "isPriority": false,
      "planMode": false,
      "parked": false,
      "autoObserver": false,
      "autoObserverPrompt": "",
      "references": [],
      "remoteConnectionLost": false,
      "hasCompletedAtLeastOnce": false,
      "hasObservedInitialAgentEvent": false,
      "lastKnownBusy": false
    }
    """
    let session = try JSONDecoder().decode(AgentSession.self, from: Data(json.utf8))
    #expect(session.terminals.count == 1)
    #expect(session.primaryTerminal.role == .shell)
    #expect(session.primaryTerminal.agent == nil)
    #expect(session.primaryTerminal.initialPrompt == "ls -la")
  }

  // MARK: New schema round-trip

  @Test func compositionSessionRoundTrips() throws {
    let sessionID = UUID()
    let shellID = UUID()
    let agentTerminal = SessionTerminal(
      id: sessionID,
      role: .agent,
      agent: .codex,
      initialPrompt: "Make it work",
      lastKnownBusy: true
    )
    let shellTerminal = SessionTerminal(id: shellID, role: .shell)
    var session = AgentSession(
      id: sessionID,
      repositoryID: "/tmp/repo",
      worktreeID: "/tmp/repo",
      agent: .codex,
      initialPrompt: "Make it work"
    )
    // Hand-rewrite terminals to give it a composition.
    session.terminals = [agentTerminal, shellTerminal]
    session.primaryTerminalID = sessionID

    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    let data = try encoder.encode(session)
    let decoded = try decoder.decode(AgentSession.self, from: data)

    #expect(decoded.id == sessionID)
    #expect(decoded.primaryTerminalID == sessionID)
    #expect(decoded.terminals.count == 2)
    #expect(decoded.terminals[0].id == sessionID)
    #expect(decoded.terminals[0].role == .agent)
    #expect(decoded.terminals[0].lastKnownBusy == true)
    #expect(decoded.terminals[1].id == shellID)
    #expect(decoded.terminals[1].role == .shell)
    #expect(decoded.auxiliaryTerminals.count == 1)
    #expect(decoded.auxiliaryTerminals[0].id == shellID)
  }

  @Test func parkedActiveDefaultsToFalseWhenMissing() throws {
    // A snapshot from before `parkedActive` existed. The decoder must
    // synthesize `false` rather than throwing.
    let sessionID = UUID()
    let json = """
    {
      "id": "\(sessionID.uuidString)",
      "repositoryID": "/tmp/repo",
      "worktreeID": "/tmp/repo",
      "currentWorkspacePath": "/tmp/repo",
      "displayName": "p",
      "createdAt": 1750000000,
      "parked": true,
      "terminals": [
        {
          "id": "\(sessionID.uuidString)",
          "role": "agent",
          "agent": "claude",
          "initialPrompt": "p",
          "createdAt": 1750000000,
          "lastActivityAt": 1750000000
        }
      ],
      "primaryTerminalID": "\(sessionID.uuidString)"
    }
    """
    let decoded = try JSONDecoder().decode(AgentSession.self, from: Data(json.utf8))
    #expect(decoded.parked == true)
    #expect(decoded.parkedActive == false)
  }

  @Test func remoteControlDefaultsToFalseWhenMissing() throws {
    // A snapshot from before `remoteControl` existed. The decoder must
    // synthesize `false` rather than throwing.
    let sessionID = UUID()
    let json = """
    {
      "id": "\(sessionID.uuidString)",
      "repositoryID": "/tmp/repo",
      "worktreeID": "/tmp/repo",
      "currentWorkspacePath": "/tmp/repo",
      "displayName": "p",
      "createdAt": 1750000000,
      "planMode": true,
      "terminals": [
        {
          "id": "\(sessionID.uuidString)",
          "role": "agent",
          "agent": "claude",
          "initialPrompt": "p",
          "createdAt": 1750000000,
          "lastActivityAt": 1750000000
        }
      ],
      "primaryTerminalID": "\(sessionID.uuidString)"
    }
    """
    let decoded = try JSONDecoder().decode(AgentSession.self, from: Data(json.utf8))
    #expect(decoded.planMode == true)
    #expect(decoded.remoteControl == false)
  }

  @Test func remoteControlRoundTrips() throws {
    let session = AgentSession(
      repositoryID: "/tmp/repo",
      worktreeID: "/tmp/repo",
      agent: .claude,
      initialPrompt: "p",
      remoteControl: true
    )
    let data = try JSONEncoder().encode(session)
    let decoded = try JSONDecoder().decode(AgentSession.self, from: data)
    #expect(decoded.remoteControl == true)
  }

  @Test func parkedActiveRoundTrips() throws {
    var session = AgentSession(
      repositoryID: "/tmp/repo",
      worktreeID: "/tmp/repo",
      agent: .claude,
      initialPrompt: "p",
      parked: true,
      parkedActive: true
    )
    // Hand-set to confirm encode/decode preserves the bit independently.
    session.parkedActive = true

    let data = try JSONEncoder().encode(session)
    let decoded = try JSONDecoder().decode(AgentSession.self, from: data)
    #expect(decoded.parked == true)
    #expect(decoded.parkedActive == true)
  }

  // MARK: Forward compatibility

  @Test func newShapeIgnoresUnknownTerminalKeys() throws {
    // A future Supacool version added a field to SessionTerminal that
    // we don't know about. Our decoder must not refuse.
    let sessionID = UUID()
    let json = """
    {
      "id": "\(sessionID.uuidString)",
      "repositoryID": "/tmp/repo",
      "worktreeID": "/tmp/repo",
      "currentWorkspacePath": "/tmp/repo",
      "displayName": "Future",
      "createdAt": 1750000000,
      "removeBackingWorktreeOnDelete": false,
      "isPriority": false,
      "planMode": false,
      "parked": false,
      "autoObserver": false,
      "autoObserverPrompt": "",
      "references": [],
      "remoteConnectionLost": false,
      "primaryTerminalID": "\(sessionID.uuidString)",
      "terminals": [
        {
          "id": "\(sessionID.uuidString)",
          "role": "agent",
          "agent": "claude",
          "initialPrompt": "Hello",
          "createdAt": 1750000000,
          "lastActivityAt": 1750000000,
          "lastKnownBusy": false,
          "hasObservedInitialAgentEvent": false,
          "hasCompletedAtLeastOnce": false,
          "futureField": { "anything": true }
        }
      ]
    }
    """
    let session = try JSONDecoder().decode(AgentSession.self, from: Data(json.utf8))
    #expect(session.terminals.count == 1)
    #expect(session.primaryTerminal.role == .agent)
    #expect(session.primaryTerminal.agent == .claude)
  }

  // MARK: Update helpers

  @Test func updatePrimaryTerminalMutatesPrimary() {
    var session = AgentSession(
      repositoryID: "/tmp/repo",
      worktreeID: "/tmp/repo",
      agent: .claude,
      initialPrompt: "First"
    )
    #expect(session.lastKnownBusy == false)
    session.updatePrimaryTerminal { $0.lastKnownBusy = true }
    #expect(session.lastKnownBusy == true)
    #expect(session.primaryTerminal.lastKnownBusy == true)
  }

  @Test func auxiliaryTerminalsExcludePrimary() {
    let sessionID = UUID()
    let shellID = UUID()
    var session = AgentSession(
      id: sessionID,
      repositoryID: "/tmp/repo",
      worktreeID: "/tmp/repo",
      agent: .claude,
      initialPrompt: "First"
    )
    session.terminals.append(SessionTerminal(id: shellID, role: .shell))
    #expect(session.terminals.count == 2)
    #expect(session.auxiliaryTerminals.count == 1)
    #expect(session.auxiliaryTerminals.first?.id == shellID)
    #expect(session.primaryTerminal.id == sessionID)
  }

  // MARK: Busy-state aggregation

  /// `session.lastKnownBusy` is the read forwarder used by the board
  /// classifier. It MUST reflect the primary (agent) terminal only — a
  /// shell sitting on `htop` should not flip the card to Working.
  @Test func lastKnownBusyForwardsFromPrimaryOnly() {
    let sessionID = UUID()
    let shellID = UUID()
    var session = AgentSession(
      id: sessionID,
      repositoryID: "/tmp/repo",
      worktreeID: "/tmp/repo",
      agent: .claude,
      initialPrompt: "Work"
    )
    // Add a "busy" shell auxiliary — primary stays idle.
    session.terminals.append(
      SessionTerminal(id: shellID, role: .shell, lastKnownBusy: true)
    )

    #expect(session.primaryTerminal.lastKnownBusy == false)
    #expect(session.lastKnownBusy == false)

    // Mark the agent busy — forwarder now flips.
    session.updatePrimaryTerminal { $0.lastKnownBusy = true }
    #expect(session.lastKnownBusy == true)
  }

  /// `session.lastActivityAt` is the freshness signal for the board
  /// card's relative timestamp and the reference-scanner staleness
  /// check. It must reflect the *newest* activity across all terminals
  /// — typing into a shell tab should bump the card's "Recently" stamp
  /// even though the agent is idle.
  @Test func lastActivityAtIsMaxAcrossAllTerminals() {
    let sessionID = UUID()
    let shellID = UUID()
    let oldDate = Date(timeIntervalSinceReferenceDate: 0)
    let newDate = Date(timeIntervalSinceReferenceDate: 1_000_000)

    var session = AgentSession(
      id: sessionID,
      repositoryID: "/tmp/repo",
      worktreeID: "/tmp/repo",
      agent: .claude,
      initialPrompt: "Work",
      lastActivityAt: oldDate
    )
    // A shell with much newer activity.
    session.terminals.append(
      SessionTerminal(id: shellID, role: .shell, lastActivityAt: newDate)
    )

    #expect(session.lastActivityAt == newDate)

    // Primary catches up — still the max.
    session.updatePrimaryTerminal { $0.lastActivityAt = newDate.addingTimeInterval(1) }
    #expect(session.lastActivityAt == newDate.addingTimeInterval(1))
  }

  /// The classifier itself takes a single `AgentActivity`. Verifies the
  /// invariant that auxiliary shells with their own busy flags do not
  /// participate: classify is fed the primary terminal's signals only,
  /// and the presence of busy auxiliaries does NOT change the result.
  @Test func shellAuxiliariesDoNotPromoteCardStatus() {
    let now = Date(timeIntervalSinceReferenceDate: 100)
    var session = AgentSession(
      repositoryID: "/tmp/repo",
      worktreeID: "/tmp/repo",
      agent: .claude,
      initialPrompt: "Work",
      lastActivityAt: now,
      hasCompletedAtLeastOnce: true,
      hasObservedInitialAgentEvent: true,
      lastKnownBusy: false
    )
    session.terminals.append(
      SessionTerminal(id: UUID(), role: .shell, lastKnownBusy: true)
    )
    session.terminals.append(
      SessionTerminal(id: UUID(), role: .shell, lastKnownBusy: true)
    )

    // Real call site reads `terminalManager.agentActivity(tabID: session.id)`
    // which targets the primary. Mirror that here: feed classify the
    // primary's activity, not anything aggregated from auxiliaries.
    let status = BoardSessionStatus.classify(
      session: session,
      tabExists: true,
      activity: session.lastKnownBusy ? .working : .idle,
      now: now
    )
    #expect(status == .waitingOnMe)
  }
}
