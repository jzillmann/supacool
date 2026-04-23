import ComposableArchitecture
import Foundation

/// Decides whether to auto-respond to a terminal prompt.
///
/// Decision is two-layered:
///   1. Pattern matching — instant, zero cost, handles common prompts.
///   2. Claude inference fallback — used when patterns don't match, or when
///      the session has custom instructions that might override a pattern match.
///
/// Returns the text to type (e.g. "1", "y") or nil to skip.
struct AutoObserverClient: Sendable {
  var decide: @Sendable (_ screenText: String, _ userInstructions: String) async -> String?
}

extension AutoObserverClient: DependencyKey {
  static let liveValue = Self { screenText, userInstructions in
    await AutoObserverLive.decide(
      screenText: screenText,
      userInstructions: userInstructions,
      inference: BackgroundInferenceClient.liveValue
    )
  }

  static let testValue = Self { _, _ in nil }
}

extension DependencyValues {
  var autoObserverClient: AutoObserverClient {
    get { self[AutoObserverClient.self] }
    set { self[AutoObserverClient.self] = newValue }
  }
}

// MARK: - Live decision logic

private nonisolated let observerLogger = SupaLogger("Supacool.AutoObserver")

private nonisolated enum AutoObserverLive {
  // MARK: Layer 1 – pattern matching

  /// Patterns applied against the last ~800 characters of screen content.
  /// Order matters: more specific patterns first.
  private static let patterns: [(pattern: String, response: String)] = [
    // Claude permission prompt: numbered list with Allow options.
    // Matches "❯ 1." or "1." at the start of a line when near Allow/Deny text.
    (#"(?i)1[.)]\s+allow"#, "1"),
    // Standard yes/no prompts — capital letter = default, don't override.
    (#"\(Y/n\)"#, "y"),
    (#"\(y/n\)"#, "y"),
    // "Press Enter to continue" / "press any key"
    (#"(?i)press enter to continue"#, "\n"),
    // Generic "Continue?" at end of last line
    (#"(?i)continue\?\s*$"#, "y"),
  ]

  static func layer1(tail: String) -> String? {
    for entry in patterns {
      guard let regex = try? Regex(entry.pattern) else { continue }
      if tail.contains(regex) {
        observerLogger.debug("Auto-observer layer-1 match: pattern=\(entry.pattern) → \(entry.response)")
        return entry.response
      }
    }
    return nil
  }

  // MARK: Layer 2 – Claude inference

  static func layer2(
    tail: String,
    userInstructions: String,
    inference: BackgroundInferenceClient
  ) async -> String? {
    var systemSection = """
      You are monitoring a macOS terminal running an AI coding agent. \
      The agent is waiting for the user to type something. \
      Your job: reply with ONLY the single key or very short string the user should type next \
      (e.g. "1", "y", "n", "q"), or reply with exactly SKIP if the right answer is not obvious \
      or if it is not safe to auto-respond.
      Rules:
      - Never reply with more than 10 characters.
      - When in doubt, reply SKIP.
      - Do not explain your answer.
      """

    if !userInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      systemSection += "\n\nSession owner instructions: \(userInstructions)"
    }

    let prompt = """
      \(systemSection)

      Terminal screen (last portion):
      \(tail)
      """

    do {
      let raw = try await inference.infer(prompt).trimmingCharacters(in: .whitespacesAndNewlines)
      if raw.uppercased() == "SKIP" || raw.isEmpty || raw.count > 10 {
        observerLogger.debug("Auto-observer layer-2: inference returned SKIP/empty/long → skip")
        return nil
      }
      observerLogger.debug("Auto-observer layer-2 decided: \(raw)")
      return raw
    } catch {
      observerLogger.warning("Auto-observer layer-2 inference failed: \(error)")
      return nil
    }
  }

  // MARK: Entry point

  static func decide(
    screenText: String,
    userInstructions: String,
    inference: BackgroundInferenceClient
  ) async -> String? {
    // Use the last 800 chars for fast pattern matching, 2000 for the LLM.
    let tail800 = String(screenText.suffix(800))
    let tail2000 = String(screenText.suffix(2000))

    // If the user supplied custom instructions, always run layer 2 (their
    // instructions may override a layer-1 pattern). Skip layer 1 fast-path
    // only when no instructions are set.
    let hasUserInstructions = !userInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

    if !hasUserInstructions, let result = layer1(tail: tail800) {
      return result
    }

    return await layer2(tail: tail2000, userInstructions: userInstructions, inference: inference)
  }
}
