import ComposableArchitecture
import Foundation

private nonisolated let sshConfigLogger = SupaLogger("Supacool.SSHConfig")

/// Reads `~/.ssh/config` and the user's effective ssh settings so Supacool
/// can auto-import hosts without rebuilding OpenSSH's config parser. The
/// `effectiveConfig` path shells out to `ssh -G <alias>` — which is
/// authoritative over Includes, Match blocks, and wildcard patterns — so
/// we never re-express Hostname/User/Port/IdentityFile ourselves.
nonisolated struct SSHConfigClient: Sendable {
  /// Returns the aliases declared at the top level of `~/.ssh/config`,
  /// excluding wildcards (`*`, patterns containing `*` or `?`). Order is
  /// preserved, duplicates removed.
  var listAliases: @Sendable () async throws -> [String]

  /// Resolves an alias by invoking `ssh -G <alias>` and parsing its output.
  /// Throws if the binary isn't found, the alias is unknown, or output
  /// can't be parsed.
  var effectiveConfig: @Sendable (_ alias: String) async throws -> EffectiveSSHConfig
}

nonisolated struct EffectiveSSHConfig: Equatable, Sendable {
  let alias: String
  let hostname: String
  let user: String?
  let port: Int?
  /// `identityfile` entries, in the order ssh reports them. Paths are
  /// expanded by `ssh -G` — no `~` left behind.
  let identityFiles: [String]
}

extension SSHConfigClient: DependencyKey {
  static let liveValue = live()

  static func live(
    shell: ShellClient = .liveValue,
    configFileURL: URL = FileManager.default
      .homeDirectoryForCurrentUser
      .appending(path: ".ssh/config", directoryHint: .notDirectory)
  ) -> SSHConfigClient {
    SSHConfigClient(
      listAliases: {
        try await readAliases(fromFile: configFileURL)
      },
      effectiveConfig: { alias in
        try await runEffectiveConfig(alias: alias, shell: shell)
      }
    )
  }

  static let testValue = SSHConfigClient(
    listAliases: {
      struct Unimplemented: Error {}
      throw Unimplemented()
    },
    effectiveConfig: { _ in
      struct Unimplemented: Error {}
      throw Unimplemented()
    }
  )
}

extension DependencyValues {
  var sshConfigClient: SSHConfigClient {
    get { self[SSHConfigClient.self] }
    set { self[SSHConfigClient.self] = newValue }
  }
}

// MARK: - Config file parsing

/// Reads Host entries from `~/.ssh/config`. We only look at top-level
/// Host lines — users with `Include` directives will miss sourced aliases,
/// which we accept as a known-gap (they can add manually). Wildcards are
/// filtered because they're patterns, not connectable aliases.
nonisolated func readAliases(fromFile url: URL) async throws -> [String] {
  let contents: String
  do {
    contents = try String(contentsOf: url, encoding: .utf8)
  } catch let error as NSError where error.code == NSFileReadNoSuchFileError {
    return []
  }
  return parseAliases(from: contents)
}

/// Pure-function parser, unit-testable without touching the filesystem.
nonisolated func parseAliases(from contents: String) -> [String] {
  var seen = Set<String>()
  var result: [String] = []
  for rawLine in contents.split(whereSeparator: \.isNewline) {
    let line = rawLine.trimmingCharacters(in: .whitespaces)
    guard !line.isEmpty, !line.hasPrefix("#") else { continue }
    // Match both "Host" and "host"; the keyword may be followed by >=1
    // whitespace-separated patterns.
    let parts = line.split(whereSeparator: \.isWhitespace)
    guard parts.count >= 2, parts[0].lowercased() == "host" else { continue }
    for pattern in parts.dropFirst() {
      let candidate = String(pattern)
      if candidate.contains("*") || candidate.contains("?") { continue }
      if candidate.hasPrefix("!") { continue }  // negation pattern
      if seen.insert(candidate).inserted {
        result.append(candidate)
      }
    }
  }
  return result
}

// MARK: - ssh -G

/// Wrapper around `/usr/bin/ssh -G <alias>`. We go through `runLogin` so
/// `$PATH` / identity agents behave like an interactive shell.
private nonisolated func runEffectiveConfig(
  alias: String,
  shell: ShellClient
) async throws -> EffectiveSSHConfig {
  let envURL = URL(fileURLWithPath: "/usr/bin/env")
  let arguments = ["ssh", "-G", alias]
  let output: ShellOutput
  do {
    output = try await shell.runLogin(envURL, arguments, nil, log: false)
  } catch {
    sshConfigLogger.warning("ssh -G failed for \(alias): \(error.localizedDescription)")
    throw error
  }
  return try parseEffectiveConfig(alias: alias, stdout: output.stdout)
}

/// Pure parser over the key-value lines emitted by `ssh -G`. Unknown keys
/// are ignored; only the handful we care about are extracted.
nonisolated func parseEffectiveConfig(
  alias: String,
  stdout: String
) throws -> EffectiveSSHConfig {
  var hostname: String?
  var user: String?
  var port: Int?
  var identityFiles: [String] = []

  for rawLine in stdout.split(whereSeparator: \.isNewline) {
    let line = rawLine.trimmingCharacters(in: .whitespaces)
    guard let spaceIdx = line.firstIndex(where: { $0.isWhitespace }) else { continue }
    let key = line[..<spaceIdx].lowercased()
    let value = line[line.index(after: spaceIdx)...].trimmingCharacters(in: .whitespaces)
    guard !value.isEmpty else { continue }

    switch key {
    case "hostname":
      hostname = value
    case "user":
      user = value
    case "port":
      port = Int(value)
    case "identityfile":
      identityFiles.append(value)
    default:
      break
    }
  }

  guard let hostname else {
    struct MissingHostname: Error, CustomStringConvertible {
      let alias: String
      var description: String { "ssh -G produced no hostname for \(alias)" }
    }
    throw MissingHostname(alias: alias)
  }

  return EffectiveSSHConfig(
    alias: alias,
    hostname: hostname,
    user: user,
    port: port,
    identityFiles: identityFiles
  )
}
