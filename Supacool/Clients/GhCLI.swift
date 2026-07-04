import Foundation

private nonisolated let ghLogger = SupaLogger("Supacool.GhCLI")

/// Run `gh` via a login shell so PATH / auth plugins are loaded. We use
/// `/usr/bin/env gh` rather than replicating upstream's executable resolver
/// — if `gh` isn't on PATH, the error surfaces to the caller, which owns
/// the presentation (non-blocking sheet warning, reducer backoff, …).
///
/// Shared by every Supacool client that shells out to `gh`
/// (`PRMonitorClient`, `SupacoolGithubPRClient`); add new `gh` callers here
/// instead of hand-rolling another spawn path.
nonisolated func runGh(shell: ShellClient, arguments: [String]) async throws -> String {
  let envURL = URL(fileURLWithPath: "/usr/bin/env")
  let ghArguments = ["gh"] + arguments
  do {
    return try await shell.runLogin(envURL, ghArguments, nil, log: false).stdout
  } catch {
    ghLogger.warning("gh invocation failed: \(error.localizedDescription)")
    throw error
  }
}
