import Foundation

/// A single first-launch onboarding card: something Supacool needs the
/// user to do before the app is fully useful. The carousel in
/// `GettingStartedCarouselView` shows one card per incomplete, non-skipped
/// task. Evaluation of which tasks are incomplete lives in
/// `GettingStartedEvaluator`; skip-set persistence is a `@Shared`
/// `[String]` of raw values in `BoardFeature.State`.
nonisolated enum GettingStartedTask: String, Codable, CaseIterable, Sendable, Hashable {
  case setupRepo
  case installHooks
  case setupRemoteHost

  var title: String {
    switch self {
    case .setupRepo: "Add a repository"
    case .installHooks: "Install coding-agent hooks"
    case .setupRemoteHost: "Add a remote host"
    }
  }

  /// One to two sentences, pitched to a fresh user. Shown under the title
  /// on each card. Keep it short — the carousel isn't a manual.
  var summary: String {
    switch self {
    case .setupRepo:
      "Pick a project folder to work on. Sessions, worktrees, and coding agents all attach to a repository."
    case .installHooks:
      "Claude Code and Codex talk to Supacool through a small hook in each agent's settings. Without it, cards can't flip when an agent needs you."
    case .setupRemoteHost:
      "Spawn terminals on any machine in your ~/.ssh/config. Import a host to run sessions over SSH."
    }
  }

  var iconName: String {
    switch self {
    case .setupRepo: "folder.badge.plus"
    case .installHooks: "bolt.badge.automatic"
    case .setupRemoteHost: "network"
    }
  }

  var ctaLabel: String {
    switch self {
    case .setupRepo: "Add repository"
    case .installHooks: "Open hook settings"
    case .setupRemoteHost: "Open remote hosts"
    }
  }
}
