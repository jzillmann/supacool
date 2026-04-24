import ComposableArchitecture
import Darwin
import Foundation

/// Lightweight inference client for quick AI tasks (e.g. branch name generation)
/// that don't warrant a full interactive Claude Code session.
///
/// Mode is configurable: Claude CLI subprocess (uses your Max subscription)
/// or direct Anthropic API (uses an API key + your choice of model).
///
/// UserDefaults keys:
///   - `supacool.inference.mode`      String: "claudeCLI" | "anthropicAPI" (default: "claudeCLI")
///   - `supacool.inference.cliModel`  String: model name, or empty for claude default
///   - `supacool.inference.apiModel`  String: model name (default: "claude-sonnet-4-6")
///   - `supacool.inference.apiKey`    String: Anthropic API key (required for API mode)
///
/// When the caller passes a `TraceContext`, the call is appended to the
/// session's transcript JSONL as a `.backgroundInference` entry, including
/// truncated prompt / result previews, wall-clock duration, and any error.
/// Call-sites with no session (branch-name generation in the New Terminal
/// sheet) pass `nil` and are not traced in v1.
struct BackgroundInferenceClient: Sendable {
  var infer: @Sendable (_ prompt: String, _ trace: InferenceTraceContext?) async throws -> String
}

/// Labels a `BackgroundInferenceClient.infer` call for the session-trace
/// JSONL. The call is recorded against `tabID`'s file with `purpose`
/// describing what Supacool asked for (e.g. `"auto-observer"`,
/// `"session-title"`). Callers with no session (branch-name generation
/// before a session exists) pass `nil` and the call is not traced.
nonisolated struct InferenceTraceContext: Sendable {
  let tabID: TerminalTabID
  let purpose: String
}

extension BackgroundInferenceClient: DependencyKey {
  static let liveValue = Self(
    infer: { prompt, trace in
      try await BackgroundInferenceLive.run(prompt: prompt, trace: trace)
    }
  )

  static let testValue = Self(
    infer: { _, _ in "mock-branch-name" }
  )
}

extension DependencyValues {
  var backgroundInferenceClient: BackgroundInferenceClient {
    get { self[BackgroundInferenceClient.self] }
    set { self[BackgroundInferenceClient.self] = newValue }
  }
}

// MARK: - Errors

nonisolated enum BackgroundInferenceError: LocalizedError {
  case claudeNotFound
  case missingAPIKey
  case commandFailed(exitCode: Int32, stderr: String)
  case invalidAPIResponse
  case timeout

  var errorDescription: String? {
    switch self {
    case .claudeNotFound:
      return "claude CLI not found. Make sure it is installed and on your PATH."
    case .missingAPIKey:
      return "Anthropic API key is required for API mode. Set it in Settings → Coding Agents."
    case .commandFailed(let exitCode, let stderr):
      let detail = stderr.isEmpty ? "exit code \(exitCode)" : stderr
      return "Inference failed: \(detail)"
    case .invalidAPIResponse:
      return "Unexpected response from the Anthropic API."
    case .timeout:
      return "Inference timed out."
    }
  }
}

// MARK: - Live implementation

private nonisolated let inferenceLogger = SupaLogger("Supacool.BackgroundInference")

/// Max chars of prompt / result recorded in the trace. Long prompts can
/// push a single trace entry to tens of kilobytes; we only need enough
/// to disambiguate "what did we ask?" and "what came back?" at a glance.
private nonisolated let inferenceTracePreviewLimit = 500

private nonisolated enum BackgroundInferenceLive {
  static func run(prompt: String, trace: InferenceTraceContext?) async throws -> String {
    let defaults = UserDefaults.standard
    let modeRaw = defaults.string(forKey: "supacool.inference.mode") ?? "claudeCLI"
    let startedAt = Date()

    do {
      let result: String
      switch modeRaw {
      case "anthropicAPI":
        let apiModel = defaults.string(forKey: "supacool.inference.apiModel") ?? "claude-sonnet-4-6"
        let apiKey = defaults.string(forKey: "supacool.inference.apiKey") ?? ""
        result = try await runAPI(prompt: prompt, model: apiModel, apiKey: apiKey)
      default:
        let cliModel = defaults.string(forKey: "supacool.inference.cliModel") ?? ""
        result = try await runCLI(prompt: prompt, model: cliModel.isEmpty ? nil : cliModel)
      }
      if let trace {
        recordTrace(
          trace: trace, mode: modeRaw, prompt: prompt, result: result,
          error: nil, startedAt: startedAt
        )
      }
      return result
    } catch {
      if let trace {
        recordTrace(
          trace: trace, mode: modeRaw, prompt: prompt, result: nil,
          error: error, startedAt: startedAt
        )
      }
      throw error
    }
  }

  private static func recordTrace(
    trace: InferenceTraceContext,
    mode: String,
    prompt: String,
    result: String?,
    error: Error?,
    startedAt: Date
  ) {
    let now = Date()
    let durationMs = Int((now.timeIntervalSince(startedAt) * 1000).rounded())
    let event = TranscriptEntry.backgroundInference(
      purpose: trace.purpose,
      mode: mode,
      promptPreview: String(prompt.prefix(inferenceTracePreviewLimit)),
      resultPreview: result.map { String($0.prefix(inferenceTracePreviewLimit)) },
      error: error.map { $0.localizedDescription },
      durationMs: durationMs,
      at: now
    )
    let tabID = trace.tabID
    Task { @MainActor in
      TranscriptRecorder.shared.append(event: event, tabID: tabID)
    }
  }

  // MARK: CLI mode

  static func runCLI(prompt: String, model: String?) async throws -> String {
    let claudeURL = try await resolveClaudePath()
    var arguments = ["-p", prompt, "--output-format", "text"]
    if let model {
      arguments += ["--model", model]
    }
    inferenceLogger.debug("Running claude CLI for inference")
    return try await runViaLoginShell(executableURL: claudeURL, arguments: arguments)
  }

  /// Resolves the absolute path to the `claude` binary by running
  /// `which claude` in a login shell (so the user's full PATH is active).
  private static func resolveClaudePath() async throws -> URL {
    let shellURL = URL(fileURLWithPath: loginShellPath())
    let whichURL = URL(fileURLWithPath: "/usr/bin/which")
    // Run: loginShell -l -c 'exec "$@"' -- /usr/bin/which claude
    let shellArgs = ["-l", "-c", "exec \"$@\"", "--", whichURL.path, "claude"]

    let process = Process()
    process.executableURL = shellURL
    process.arguments = shellArgs
    let outputPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = Pipe()

    return try await withCheckedThrowingContinuation { continuation in
      process.terminationHandler = { p in
        if p.terminationStatus == 0 {
          let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
          let path = String(bytes: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
          if !path.isEmpty {
            continuation.resume(returning: URL(fileURLWithPath: path))
          } else {
            continuation.resume(throwing: BackgroundInferenceError.claudeNotFound)
          }
        } else {
          continuation.resume(throwing: BackgroundInferenceError.claudeNotFound)
        }
      }
      do {
        try process.run()
      } catch {
        continuation.resume(throwing: BackgroundInferenceError.claudeNotFound)
      }
    }
  }

  /// Runs an executable via the user's login shell, passing arguments directly
  /// (no shell string interpolation). Mirrors `ShellClient.runLogin` without
  /// requiring a ShellClient dependency.
  private static func runViaLoginShell(
    executableURL: URL,
    arguments: [String]
  ) async throws -> String {
    let shellURL = URL(fileURLWithPath: loginShellPath())
    // Run: loginShell -l -c 'exec "$@"' -- <executableURL> <arguments...>
    // The exec "$@" script forwards everything after -- to exec, so the
    // arguments reach the target binary without any shell interpretation.
    let shellArgs = ["-l", "-c", "exec \"$@\"", "--", executableURL.path] + arguments

    let process = Process()
    process.executableURL = shellURL
    process.arguments = shellArgs
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    return try await withCheckedThrowingContinuation { continuation in
      process.terminationHandler = { p in
        let stdout = String(bytes: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
          .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if p.terminationStatus == 0 {
          continuation.resume(returning: stdout)
        } else if p.terminationStatus == 127 {
          continuation.resume(throwing: BackgroundInferenceError.claudeNotFound)
        } else {
          let stderr = String(bytes: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
          continuation.resume(
            throwing: BackgroundInferenceError.commandFailed(
              exitCode: p.terminationStatus,
              stderr: stderr
            )
          )
        }
      }
      do {
        try process.run()
      } catch {
        continuation.resume(throwing: error)
      }
    }
  }

  // MARK: API mode

  static func runAPI(prompt: String, model: String, apiKey: String) async throws -> String {
    guard !apiKey.isEmpty else {
      throw BackgroundInferenceError.missingAPIKey
    }

    let url = URL(string: "https://api.anthropic.com/v1/messages")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

    let body: [String: Any] = [
      "model": model,
      "max_tokens": 100,
      "messages": [["role": "user", "content": prompt]],
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    inferenceLogger.debug("Calling Anthropic API for inference, model=\(model)")

    let (data, _) = try await URLSession.shared.data(for: request)
    guard
      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let content = (json["content"] as? [[String: Any]])?.first,
      let text = content["text"] as? String
    else {
      throw BackgroundInferenceError.invalidAPIResponse
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // MARK: Helpers

  /// Returns the user's configured login shell path, falling back to /bin/zsh.
  /// Mirrors `defaultShellPath()` in ShellClient.swift.
  private static func loginShellPath() -> String {
    if let env = ProcessInfo.processInfo.environment["SHELL"], !env.isEmpty {
      return env
    }
    var pwd = passwd()
    var result: UnsafeMutablePointer<passwd>?
    let bufSize = sysconf(_SC_GETPW_R_SIZE_MAX)
    let size = bufSize > 0 ? Int(bufSize) : 1024
    var buffer = [CChar](repeating: 0, count: size)
    let lookup = getpwuid_r(getuid(), &pwd, &buffer, buffer.count, &result)
    if lookup == 0, let result, let shell = result.pointee.pw_shell {
      let value = String(cString: shell)
      if !value.isEmpty { return value }
    }
    return "/bin/zsh"
  }
}

// MARK: - Branch name sanitizer

/// Cleans a raw AI-generated response into a valid git branch name:
/// kebab-case, alphanumeric + hyphens only, max 40 chars.
nonisolated func sanitizeBranchName(_ raw: String) -> String {
  // Take only the first non-empty line (model may add explanations below).
  let firstLine =
    raw.components(separatedBy: .newlines)
    .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
    ?? raw

  var result = firstLine
    .trimmingCharacters(in: .whitespacesAndNewlines)
    .lowercased()

  // Replace whitespace and underscores with hyphens.
  result = result.replacing(/[\s_]+/, with: "-")
  // Remove any character that isn't alphanumeric or a hyphen/slash.
  result = result.replacing(/[^a-z0-9\-\/]/, with: "")
  // Collapse consecutive hyphens.
  result = result.replacing(/\-{2,}/, with: "-")
  // Strip leading/trailing hyphens and slashes.
  result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-/"))
  // Truncate.
  return String(result.prefix(40))
}
