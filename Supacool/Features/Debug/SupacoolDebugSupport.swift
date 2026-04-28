import Foundation

/// Helpers for the "Debug session" feature: finding the registered
/// supacool repository, building the debug-session worktree name, and
/// producing the templated initial prompt that hands the agent its
/// observation + trace path.
enum SupacoolDebugSupport {
  /// Returns the first registered repository whose root contains
  /// `supacool.xcodeproj`. The "Debug session" flow spawns its agent in
  /// this repo so it has the codebase to act on findings.
  ///
  /// Detection is structural rather than name-based — users may have
  /// renamed the cloned directory, but they can't remove the project
  /// file without breaking the build.
  static func findSupacoolRepository(in repositories: [Repository]) -> Repository? {
    let fm = FileManager.default
    return repositories.first { repo in
      let project = repo.rootURL.appending(
        path: "supacool.xcodeproj", directoryHint: .isDirectory
      )
      return fm.fileExists(atPath: project.path)
    }
  }

  /// Worktree (and therefore branch) name for a debug session.
  /// Pattern: `debug_<sourceSlug>_<HHmm>`. The minute-precision suffix
  /// disambiguates multiple debug sessions spawned from the same source
  /// in close succession without growing unbounded across the day.
  static func debugWorktreeName(
    sourceDisplayName: String,
    now: Date = Date(),
    calendar: Calendar = .current
  ) -> String {
    let slug = slugify(sourceDisplayName)
    let components = calendar.dateComponents([.hour, .minute], from: now)
    let stamp = String(
      format: "%02d%02d", components.hour ?? 0, components.minute ?? 0
    )
    let base = slug.isEmpty ? "session" : slug
    return "debug_\(base)_\(stamp)"
  }

  /// Stable display-name format for debug sessions. Avoids endlessly
  /// stacking prefixes when the user debugs a debug session.
  static func debugDisplayName(sourceDisplayName: String) -> String {
    let trimmed = sourceDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
    let base = trimmed.hasPrefix("Debug: ")
      ? String(trimmed.dropFirst("Debug: ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
      : trimmed
    return "Debug: \(base)"
  }

  /// Prompt template handed to the debug agent. The agent receives the
  /// user's observation, knows the absolute path to the source session's
  /// trace JSONL, and is told it has the supacool codebase available at
  /// the worktree root.
  static func buildDebugPrompt(
    observation: String,
    sourceSession: AgentSession,
    tracePath: String
  ) -> String {
    let trimmedObservation = observation.trimmingCharacters(in: .whitespacesAndNewlines)
    let agentLabel = sourceSession.agent?.id ?? "shell"
    let initialPrompt = sourceSession.initialPrompt.isEmpty
      ? "(no initial prompt recorded)"
      : sourceSession.initialPrompt
    return """
      I'm debugging a Supacool agent session. Here's what I noticed:

      \(trimmedObservation)

      The full structured event trace for the source session is at:

        \(tracePath)

      Source session details:
        - Session ID: \(sourceSession.id.uuidString)
        - Agent: \(agentLabel)
        - Initial prompt: \(initialPrompt)
        - Worktree: \(sourceSession.worktreeID)

      Please:
        1. Read the trace JSONL with the Read tool — it's append-only
           with one TranscriptEntry per line. Look at `kind` to see
           the event mix (input, outputTurn, hookEvent,
           awaitingInputChanged, sessionLifecycle, autoObserver,
           backgroundInference). Schema lives in
           Supacool/Features/Transcript/TranscriptEntry.swift.
        2. Build a timeline that explains the user's observation —
           pay attention to hookEvent classifier verdicts and
           awaitingInputChanged source fields.
        3. Identify the root cause and propose a concrete fix in
           the Supacool codebase. The supacool source is at this
           worktree's root (Supacool/, supacode/, supacoolTests/).

      Don't modify any files yet — first walk me through your
      analysis and the proposed fix.
      """
  }

  /// Lowercased, hyphen-collapsed, alphanumeric-only slug usable as a
  /// segment of a git branch / worktree name.
  private static func slugify(_ raw: String) -> String {
    let lowered = raw.lowercased()
    let mapped = lowered.map { ch -> Character in
      if ch.isLetter || ch.isNumber {
        return ch
      }
      return "-"
    }
    var result = String(mapped)
      .replacing(/-{2,}/, with: "-")
    result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return String(result.prefix(24))
  }
}
