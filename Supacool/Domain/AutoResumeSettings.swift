import Foundation

/// Per-case configuration for Phase-3 PR auto-resume: which mechanical
/// PR-return reasons hand the fix straight back to the idle agent, and the
/// exact instruction text injected for each. When several conditions apply
/// to the same PR snapshot at once (e.g. CI failed *and* Greptile flagged
/// it), the enabled cases' texts are combined into one injected prompt.
///
/// Lives in UserDefaults (board-local behaviour, same as the pre-existing
/// master flag) rather than the persisted GlobalSettings file — no Codable
/// schema to migrate. The Settings UI writes the same keys via `@AppStorage`.
nonisolated struct AutoResumeSettings: Equatable, Sendable {
  /// Master switch — the pre-existing `supacool.autoResumeOnPRReturn` flag.
  var enabled: Bool
  var caseSettings: [Case: CaseSetting]

  nonisolated struct CaseSetting: Equatable, Sendable {
    var enabled: Bool
    var template: String
  }

  nonisolated enum Case: String, CaseIterable, Sendable, Identifiable {
    case ciFailed
    case mergeConflict
    case greptileLow

    var id: String { rawValue }

    var title: String {
      switch self {
      case .ciFailed: return "CI failure"
      case .mergeConflict: return "Merge conflict"
      case .greptileLow: return "Low Greptile score"
      }
    }

    /// Placeholders this case's template understands, for the settings UI.
    var placeholderHint: String? {
      switch self {
      case .ciFailed: return "{count} → number of failing checks"
      case .greptileLow: return "{score} → the Greptile score (out of 5)"
      case .mergeConflict: return nil
      }
    }

    var enabledDefaultsKey: String { "supacool.autoResume.\(rawValue).enabled" }
    var templateDefaultsKey: String { "supacool.autoResume.\(rawValue).template" }

    var defaultTemplate: String {
      switch self {
      case .ciFailed:
        return
          "CI failed on this pull request ({count} failing). Run `gh pr checks` to see which, "
          + "investigate the failure, fix it, and push."
      case .mergeConflict:
        return
          "This pull request has merge conflicts. Update the branch against its base, resolve "
          + "the conflicts locally, run the relevant checks, and push the resolution."
      case .greptileLow:
        return
          "Greptile flagged this pull request with a low confidence score ({score}/5). Review "
          + "the Greptile review comments on the PR, address the concerns, and push."
      }
    }

    /// The auto-resume case a mechanical ball state maps to; nil for
    /// human-judgment / their-court / done states.
    init?(_ state: PRBallState) {
      switch state {
      case .ciFailed: self = .ciFailed
      case .mergeConflict: self = .mergeConflict
      case .greptileLow: self = .greptileLow
      default: return nil
      }
    }
  }

  static let globalEnabledDefaultsKey = "supacool.autoResumeOnPRReturn"

  /// Reads the live configuration straight from UserDefaults (mirrors
  /// `readBypassPermissions`); the Settings toggles write the same keys via
  /// `@AppStorage`. Cases default to enabled with their built-in template, so
  /// flipping the master switch on preserves the historical behaviour.
  static func load(from defaults: UserDefaults = .standard) -> AutoResumeSettings {
    var caseSettings: [Case: CaseSetting] = [:]
    for kind in Case.allCases {
      let enabled = defaults.object(forKey: kind.enabledDefaultsKey) as? Bool ?? true
      let stored = defaults.string(forKey: kind.templateDefaultsKey) ?? ""
      let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
      caseSettings[kind] = CaseSetting(
        enabled: enabled,
        template: trimmed.isEmpty ? kind.defaultTemplate : stored
      )
    }
    return AutoResumeSettings(
      enabled: defaults.bool(forKey: globalEnabledDefaultsKey),
      caseSettings: caseSettings
    )
  }

  /// Renders the instruction to inject for the mechanical conditions present
  /// on a PR snapshot, combining the enabled cases' templates (in triage
  /// order) when several apply at once. `nil` when no applicable case is
  /// enabled — the caller falls back to a notification.
  func prompt(for conditions: [PRBallState]) -> String? {
    let parts =
      conditions
      .sorted { $0.triagePriority < $1.triagePriority }
      .compactMap { condition -> String? in
        guard let kind = Case(condition),
          let setting = caseSettings[kind], setting.enabled
        else { return nil }
        return Self.render(setting.template, condition: condition)
      }
    guard !parts.isEmpty else { return nil }
    return parts.joined(separator: "\n\n")
  }

  private static func render(_ template: String, condition: PRBallState) -> String {
    switch condition {
    case .ciFailed(let count):
      return template.replacing("{count}", with: "\(count)")
    case .greptileLow(let score):
      return template.replacing("{score}", with: "\(score)")
    default:
      return template
    }
  }
}
