import ComposableArchitecture
import Foundation

nonisolated enum ServerLifecycleScriptKind: String, Sendable {
  case status
  case start
  case stop
}

nonisolated struct ServerLifecycleScriptContext: Equatable, Sendable {
  let event: String
  let sessionID: String?
  let sessionName: String?

  init(event: String, sessionID: String? = nil, sessionName: String? = nil) {
    self.event = event
    self.sessionID = sessionID
    self.sessionName = sessionName
  }
}

nonisolated struct ServerLifecycleScriptResult: Equatable, Sendable {
  let exitCode: Int32
  let stdout: String
  let stderr: String

  /// Both streams together, in the order a human reading the terminal would
  /// see them. The scanner wants the whole thing, not just the first line —
  /// a `dev status` prints its ports well below its header.
  var combinedOutput: String {
    [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
  }

  var firstOutputLine: String? {
    combinedOutput
      .split(whereSeparator: \.isNewline)
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
      .first { !$0.isEmpty }
  }
}

// `nonisolated` so the lifecycle script runner, which is off the main actor,
// can strip without awaiting — global `@MainActor` isolation would otherwise
// claim this extension.
nonisolated extension String {
  /// Lifecycle scripts run under a login shell, so tools that colourise their
  /// output do so here too — the codes then travel intact into any UI that
  /// shows the text. (`dev status` bolds its header, which surfaced in the
  /// board chip's tooltip as a literal `[1mService Status[0m`.)
  var strippingANSIEscapeCodes: String {
    replacing(/\u{1B}\[[0-9;?]*[a-zA-Z]/, with: "")
  }
}

nonisolated struct ServerLifecycleClient: Sendable {
  var run: @Sendable (
    Worktree,
    ServerLifecycleScriptKind,
    String,
    ServerLifecycleScriptContext
  ) async throws -> ServerLifecycleScriptResult
}

extension ServerLifecycleClient: DependencyKey {
  static let liveValue = ServerLifecycleClient { worktree, kind, script, context in
    try await runServerLifecycleScript(worktree: worktree, kind: kind, script: script, context: context)
  }

  static let testValue = ServerLifecycleClient { _, _, _, _ in
    ServerLifecycleScriptResult(exitCode: 0, stdout: "", stderr: "")
  }
}

extension DependencyValues {
  var serverLifecycleClient: ServerLifecycleClient {
    get { self[ServerLifecycleClient.self] }
    set { self[ServerLifecycleClient.self] = newValue }
  }
}

private nonisolated let serverLifecycleLogger = SupaLogger("ServerLifecycle")

nonisolated private func runServerLifecycleScript(
  worktree: Worktree,
  kind: ServerLifecycleScriptKind,
  script: String,
  context: ServerLifecycleScriptContext
) async throws -> ServerLifecycleScriptResult {
  let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else {
    return ServerLifecycleScriptResult(exitCode: 0, stdout: "", stderr: "")
  }

  let fileManager = FileManager.default
  let directoryURL = fileManager.temporaryDirectory.appending(
    path: "supacool-server-lifecycle-\(UUID().uuidString.lowercased())",
    directoryHint: .isDirectory
  )
  let scriptURL = directoryURL.appending(path: "script", directoryHint: .notDirectory)
  try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
  defer { try? fileManager.removeItem(at: directoryURL) }
  try Data((trimmed + "\n").utf8).write(to: scriptURL, options: [.atomic])

  let process = Process()
  process.executableURL = URL(fileURLWithPath: defaultShellPath())
  process.arguments = ["-l", scriptURL.path(percentEncoded: false)]
  process.currentDirectoryURL = worktree.workingDirectory
  var environment = ProcessInfo.processInfo.environment
  environment.merge(worktree.scriptEnvironment) { _, new in new }
  environment["SUPACOOL_LIFECYCLE_KIND"] = kind.rawValue
  environment["SUPACOOL_EVENT"] = context.event
  if let sessionID = context.sessionID {
    environment["SUPACOOL_SESSION_ID"] = sessionID
  }
  if let sessionName = context.sessionName {
    environment["SUPACOOL_SESSION_NAME"] = sessionName
  }
  process.environment = environment

  let stdoutPipe = Pipe()
  let stderrPipe = Pipe()
  process.standardInput = FileHandle.nullDevice
  process.standardOutput = stdoutPipe
  process.standardError = stderrPipe

  // `Process.terminationStatus` raises an uncatchable Objective-C exception if read while the
  // task is not in a terminated state (e.g. the working directory was deleted out from under a
  // worktree teardown script). Capture it inside the termination handler, where Foundation
  // guarantees the status is valid, so a background lifecycle script can never abort the app.
  let terminationStatus = LockIsolated<Int32>(0)
  let (terminationStream, terminationContinuation) = AsyncStream.makeStream(of: Void.self)
  process.terminationHandler = { process in
    terminationStatus.setValue(process.terminationStatus)
    terminationContinuation.finish()
  }

  serverLifecycleLogger.debug(
    "Running \(kind.rawValue) lifecycle script in \(worktree.workingDirectory.path(percentEncoded: false))"
  )
  try process.run()

  async let stdoutData = stdoutPipe.fileHandleForReading.readToEnd() ?? Data()
  async let stderrData = stderrPipe.fileHandleForReading.readToEnd() ?? Data()
  for await _ in terminationStream {}

  let stdout = String(data: try await stdoutData, encoding: .utf8) ?? ""
  let stderr = String(data: try await stderrData, encoding: .utf8) ?? ""
  return ServerLifecycleScriptResult(
    exitCode: terminationStatus.value,
    stdout: stdout.strippingANSIEscapeCodes.trimmingCharacters(in: .whitespacesAndNewlines),
    stderr: stderr.strippingANSIEscapeCodes.trimmingCharacters(in: .whitespacesAndNewlines)
  )
}
