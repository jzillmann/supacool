import Foundation
import Testing

@testable import Supacool

struct AgentHookCommandTests {
  // MARK: - Command generation.

  @Test func busyActiveCommandContainsFlag1() {
    let command = AgentHookSettingsCommand.busyCommand(active: true)
    #expect(command.contains("$SUPACOOL_SURFACE_ID 1 $PPID"))
  }

  @Test func busyInactiveCommandContainsFlag0() {
    let command = AgentHookSettingsCommand.busyCommand(active: false)
    #expect(command.contains("$SUPACOOL_SURFACE_ID 0 $PPID"))
  }

  @Test func busyCommandPassesPPIDAsFifthField() {
    let command = AgentHookSettingsCommand.busyCommand(active: true)
    #expect(command.contains("$PPID"))
  }

  @Test func historicalBusyCommandsAreTheTwoPreviousShapes() {
    let historical = AgentHookSettingsCommand.historicalBusyCommands
    #expect(historical.count == 2)
    // Neither of the historical strings should contain $PPID — that's
    // the whole point. They also must NOT match the current output,
    // otherwise upgrading would re-prune a valid install.
    for historicalCommand in historical {
      #expect(!historicalCommand.contains("$PPID"))
      #expect(historicalCommand != AgentHookSettingsCommand.busyCommand(active: true))
      #expect(historicalCommand != AgentHookSettingsCommand.busyCommand(active: false))
    }
  }

  @Test func historicalBusyCommandsAreRecognizedAsManaged() {
    for historicalCommand in AgentHookSettingsCommand.historicalBusyCommands {
      #expect(AgentHookCommandOwnership.isSupacoolManagedCommand(historicalCommand))
    }
  }

  @Test func busyCommandChecksAllFourEnvVars() {
    let command = AgentHookSettingsCommand.busyCommand(active: true)
    #expect(command.contains("SUPACOOL_SOCKET_PATH"))
    #expect(command.contains("SUPACOOL_WORKTREE_ID"))
    #expect(command.contains("SUPACOOL_TAB_ID"))
    #expect(command.contains("SUPACOOL_SURFACE_ID"))
  }

  @Test func busyCommandSuppressesErrors() {
    let command = AgentHookSettingsCommand.busyCommand(active: true)
    #expect(command.hasSuffix("2>/dev/null || true"))
  }

  @Test func notificationCommandIncludesAgent() {
    let command = AgentHookSettingsCommand.notificationCommand(agent: "claude")
    #expect(command.contains("claude"))
  }

  @Test func notificationCommandIncludesAllThreeIDs() {
    let command = AgentHookSettingsCommand.notificationCommand(agent: "codex")
    #expect(command.contains("$SUPACOOL_WORKTREE_ID"))
    #expect(command.contains("$SUPACOOL_TAB_ID"))
    #expect(command.contains("$SUPACOOL_SURFACE_ID"))
  }

  // MARK: - preToolUseCommand.

  @Test func preToolUseCommandBranchesOnBlockingTools() {
    let command = AgentHookSettingsCommand.preToolUseCommand(agent: "claude")
    #expect(command.contains("AskUserQuestion"))
    #expect(command.contains("ExitPlanMode"))
  }

  @Test func preToolUseCommandFallsBackToBusyForOtherTools() {
    let command = AgentHookSettingsCommand.preToolUseCommand(agent: "claude")
    // The default branch sends the same busy=1 + PPID line as busyCommand.
    #expect(command.contains("$SUPACOOL_SURFACE_ID 1 $PPID"))
  }

  @Test func preToolUseCommandSendsSyntheticAwaitingInputNotification() {
    let command = AgentHookSettingsCommand.preToolUseCommand(agent: "claude")
    // Blocking-tool branch must produce a Notification-event JSON body
    // whose "message" matches the awaiting-input keyword list (see
    // WorktreeTerminalManager.isAwaitingInputSignal).
    #expect(command.contains(#""hook_event_name":"Notification""#))
    #expect(command.contains("waiting for your input"))
  }

  @Test func preToolUseCommandEmitsValidJSONBody() throws {
    // Regression: the previous body string was missing the opening quote
    // on `"message"` — the JSON failed to decode and the socket server
    // silently dropped every synthetic Notification. Substring `contains`
    // checks above would happily pass the broken version, so this test
    // asserts the actual `printf '…'` payload decodes cleanly.
    let command = AgentHookSettingsCommand.preToolUseCommand(agent: "claude")
    let needle = #"printf '%s\n' '"#
    let bodyStart = try #require(command.range(of: needle)).upperBound
    let bodyEnd = try #require(command[bodyStart...].firstIndex(of: "'"))
    let json = String(command[bodyStart..<bodyEnd])

    struct Payload: Decodable {
      let hook_event_name: String  // swiftlint:disable:this identifier_name
      let message: String
    }
    let payload = try JSONDecoder().decode(Payload.self, from: Data(json.utf8))
    #expect(payload.hook_event_name == "Notification")
    #expect(payload.message.lowercased().contains("waiting for your input"))
  }

  @Test func historicalPreToolUseCommandsAreSupacoolManaged() {
    // The historical (broken) variants must still register as Supacool-
    // owned so re-install can prune them out of live settings.json.
    for command in AgentHookSettingsCommand.historicalPreToolUseCommands {
      #expect(AgentHookCommandOwnership.isSupacoolManagedCommand(command))
      #expect(command != AgentHookSettingsCommand.preToolUseCommand(agent: "claude"))
    }
  }

  @Test func preToolUseCommandIsSupacoolManaged() {
    let command = AgentHookSettingsCommand.preToolUseCommand(agent: "claude")
    #expect(AgentHookCommandOwnership.isSupacoolManagedCommand(command))
  }

  @Test func preToolUseCommandChecksAllFourEnvVars() {
    let command = AgentHookSettingsCommand.preToolUseCommand(agent: "claude")
    #expect(command.contains("SUPACOOL_SOCKET_PATH"))
    #expect(command.contains("SUPACOOL_WORKTREE_ID"))
    #expect(command.contains("SUPACOOL_TAB_ID"))
    #expect(command.contains("SUPACOOL_SURFACE_ID"))
  }

  @Test func preToolUseCommandSuppressesErrors() {
    let command = AgentHookSettingsCommand.preToolUseCommand(agent: "claude")
    #expect(command.hasSuffix("2>/dev/null || true"))
  }

  // MARK: - Command ownership.

  @Test func currentCommandIsRecognized() {
    let command = AgentHookSettingsCommand.busyCommand(active: true)
    #expect(AgentHookCommandOwnership.isSupacoolManagedCommand(command))
  }

  @Test func notificationCommandIsRecognized() {
    let command = AgentHookSettingsCommand.notificationCommand(agent: "claude")
    #expect(AgentHookCommandOwnership.isSupacoolManagedCommand(command))
  }

  @Test func legacyCommandIsRecognized() {
    let legacy = "SUPACOOL_CLI_PATH=/usr/bin/supacode agent-hook --stop"
    #expect(AgentHookCommandOwnership.isSupacoolManagedCommand(legacy))
    #expect(AgentHookCommandOwnership.isLegacyCommand(legacy))
  }

  @Test func legacyCommandRequiresBothMarkers() {
    #expect(!AgentHookCommandOwnership.isLegacyCommand("SUPACOOL_CLI_PATH only"))
    #expect(!AgentHookCommandOwnership.isLegacyCommand("agent-hook only"))
  }

  @Test func unrelatedCommandIsNotRecognized() {
    #expect(!AgentHookCommandOwnership.isSupacoolManagedCommand("echo hello"))
    #expect(!AgentHookCommandOwnership.isSupacoolManagedCommand(nil))
  }

  @Test func currentCommandIsNotLegacy() {
    let command = AgentHookSettingsCommand.busyCommand(active: true)
    #expect(!AgentHookCommandOwnership.isLegacyCommand(command))
  }

  // MARK: - Shared constants consistency.

  @Test func socketPathEnvVarPresentInGeneratedCommands() {
    let busy = AgentHookSettingsCommand.busyCommand(active: true)
    let notify = AgentHookSettingsCommand.notificationCommand(agent: "test")
    #expect(busy.contains(AgentHookSettingsCommand.socketPathEnvVar))
    #expect(notify.contains(AgentHookSettingsCommand.socketPathEnvVar))
  }
}
