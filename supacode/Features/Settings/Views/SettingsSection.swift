import Foundation

enum SettingsSection: Hashable, Sendable {
  case general
  case notifications
  case worktree
  case codingAgents
  case shortcuts
  case updates
  case github
  case remoteHosts
  case repository(Repository.ID)
}
