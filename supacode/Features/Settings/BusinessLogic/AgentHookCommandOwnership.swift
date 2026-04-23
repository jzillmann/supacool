nonisolated enum AgentHookCommandOwnership {
  /// Returns `true` when the command was installed by Supacool.
  static func isSupacoolManagedCommand(_ command: String?) -> Bool {
    guard let command else { return false }
    if command.contains(AgentHookSettingsCommand.socketPathEnvVar) { return true }
    return isLegacyCommand(command)
  }

  /// Returns `true` for commands from older Supacool versions.
  static func isLegacyCommand(_ command: String) -> Bool {
    command.contains(AgentHookSettingsCommand.legacyCLIPathEnvVar)
      && command.contains(AgentHookSettingsCommand.legacyAgentHookMarker)
  }
}
