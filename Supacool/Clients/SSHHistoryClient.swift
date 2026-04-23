import ComposableArchitecture
import Foundation

private nonisolated let sshHistoryLogger = SupaLogger("Supacool.SSHHistory")

/// Scans the user's shell history for `ssh` invocations so Supacool can
/// offer to import hosts that were never added to `~/.ssh/config`. Reads
/// `~/.zsh_history` (extended format with timestamps) and
/// `~/.bash_history` (untimestamped). Produces a dedup'd list of
/// candidates — the user decides which ones to keep.
///
/// No shelling out: we read the raw files and parse in-process so the
/// live client is usable from a test harness.
nonisolated struct SSHHistoryClient: Sendable {
  /// Returns all distinct `(user, hostname, port, identityFile)` tuples
  /// observed in the user's history files, ranked by `lastSeenAt`
  /// descending (nil sort last).
  var listCandidates: @Sendable () async throws -> [SSHHistoryCandidate]
}

nonisolated struct SSHHistoryCandidate: Identifiable, Hashable, Sendable {
  /// `user@host`-style id used for UI selection keys. Port / identity
  /// are not in the id so re-imports with the same target merge cleanly.
  var id: String { "\(user ?? "")@\(hostname):\(port ?? 0)" }
  /// A representative raw command (first observation). Used only for the
  /// tooltip / preview row — not parsed further downstream.
  let raw: String
  let user: String?
  let hostname: String
  let port: Int?
  let identityFile: String?
  let timesSeen: Int
  let lastSeenAt: Date?
}

extension SSHHistoryClient: DependencyKey {
  static let liveValue = live()

  static func live(
    zshHistoryURL: URL = FileManager.default
      .homeDirectoryForCurrentUser
      .appending(path: ".zsh_history", directoryHint: .notDirectory),
    bashHistoryURL: URL = FileManager.default
      .homeDirectoryForCurrentUser
      .appending(path: ".bash_history", directoryHint: .notDirectory)
  ) -> SSHHistoryClient {
    SSHHistoryClient(
      listCandidates: {
        try await readCandidates(
          zshHistoryURL: zshHistoryURL,
          bashHistoryURL: bashHistoryURL
        )
      }
    )
  }

  static let testValue = SSHHistoryClient(
    listCandidates: {
      struct Unimplemented: Error {}
      throw Unimplemented()
    }
  )
}

extension DependencyValues {
  var sshHistoryClient: SSHHistoryClient {
    get { self[SSHHistoryClient.self] }
    set { self[SSHHistoryClient.self] = newValue }
  }
}

// MARK: - File reading

/// Reads both history files if present and merges the candidates. A
/// missing file isn't an error — we just produce nothing from it.
nonisolated func readCandidates(
  zshHistoryURL: URL,
  bashHistoryURL: URL
) async throws -> [SSHHistoryCandidate] {
  var observations: [RawObservation] = []

  if let zshContents = try? readHistoryFile(at: zshHistoryURL) {
    observations.append(contentsOf: parseZshHistory(zshContents))
  }
  if let bashContents = try? readHistoryFile(at: bashHistoryURL) {
    observations.append(contentsOf: parseBashHistory(bashContents))
  }

  return rollUp(observations: observations)
}

/// zsh history files occasionally contain bytes that aren't valid UTF-8
/// (pastes, Unicode corruption). Fall back to a lossy decode so one
/// broken line doesn't prevent the whole scan from running.
private nonisolated func readHistoryFile(at url: URL) throws -> String {
  let data = try Data(contentsOf: url)
  if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
  return String(decoding: data, as: UTF8.self)
}

// MARK: - Parsing

/// One parsed `ssh` invocation observed in a history file. Collapsed
/// into `SSHHistoryCandidate` by `rollUp(observations:)`.
nonisolated struct RawObservation: Equatable, Sendable {
  let raw: String
  let user: String?
  let hostname: String
  let port: Int?
  let identityFile: String?
  let timestamp: Date?
}

/// Parses zsh's extended history format:
///     `: <unix-ts>:<elapsed>;<command>`
/// Bare lines (`command`) are also accepted — older zsh configs.
nonisolated func parseZshHistory(_ contents: String) -> [RawObservation] {
  var out: [RawObservation] = []
  for rawLine in contents.split(whereSeparator: \.isNewline) {
    let line = String(rawLine)
    let (command, timestamp) = stripZshExtendedPrefix(line)
    guard let observation = parseSSHCommand(command, timestamp: timestamp) else { continue }
    out.append(observation)
  }
  return out
}

/// Strips the `: <ts>:<elapsed>;` prefix if present. Returns the command
/// payload and a `Date` parsed from the ts when available.
nonisolated func stripZshExtendedPrefix(_ line: String) -> (String, Date?) {
  guard line.hasPrefix(": ") else { return (line, nil) }
  guard let semicolon = line.firstIndex(of: ";") else { return (line, nil) }
  let prefix = line[line.index(line.startIndex, offsetBy: 2)..<semicolon]
  let command = String(line[line.index(after: semicolon)...])
  // Prefix is `<ts>:<elapsed>` — split once.
  let parts = prefix.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
  guard let tsString = parts.first, let ts = TimeInterval(tsString) else {
    return (command, nil)
  }
  return (command, Date(timeIntervalSince1970: ts))
}

nonisolated func parseBashHistory(_ contents: String) -> [RawObservation] {
  var out: [RawObservation] = []
  for rawLine in contents.split(whereSeparator: \.isNewline) {
    let line = String(rawLine)
    // bash HISTTIMEFORMAT lines look like `#1703512345` followed by the
    // command on the next line. We treat `#…` prefix lines as comments
    // (no timestamp attached, since pairing them correctly would
    // complicate the parser for little gain).
    if line.hasPrefix("#") { continue }
    guard let observation = parseSSHCommand(line, timestamp: nil) else { continue }
    out.append(observation)
  }
  return out
}

/// Extracts the ssh target + flags from a single command line, if it's
/// an ssh invocation. Returns `nil` for anything that isn't an ssh
/// command or that we can't cleanly parse (e.g. ssh inside a subshell).
nonisolated func parseSSHCommand(_ command: String, timestamp: Date?) -> RawObservation? {
  let tokens = shellTokens(from: command)
  // Locate the `ssh` token. If the line starts with a wrapper we
  // recognize (e.g. `sudo`, `time`, `nice`), skip past it; otherwise
  // the first token has to be `ssh`.
  guard let sshIndex = locateSSHToken(in: tokens) else { return nil }

  var user: String?
  var hostname: String?
  var port: Int?
  var identityFile: String?
  var idx = sshIndex + 1

  while idx < tokens.count {
    let token = tokens[idx]
    // End-of-options separator; remaining non-flag token is the target.
    if token == "--" {
      idx += 1
      break
    }
    // Single `-` isn't a flag — bail.
    if token == "-" {
      idx += 1
      continue
    }
    guard token.hasPrefix("-") else { break }

    switch token {
    case "-p":
      idx += 1
      if idx < tokens.count, let p = Int(tokens[idx]) { port = p }
    case "-i":
      idx += 1
      if idx < tokens.count { identityFile = tokens[idx] }
    case "-l":
      idx += 1
      if idx < tokens.count { user = tokens[idx] }
    case "-o":
      idx += 1
      if idx < tokens.count {
        parseSSHOptionFlag(tokens[idx], into: &user, port: &port, identityFile: &identityFile)
      }
    default:
      // Flags with arguments we don't care about (-F, -J, -S, -D, -R, -L, -W, etc.).
      if sshFlagsTakingArgument.contains(token) {
        idx += 1
      }
      // Flags without arguments: -4, -6, -A, -a, -C, -f, -G, -g, -K, -k,
      // -M, -N, -n, -q, -s, -T, -t, -V, -v, -X, -x, -Y, -y — just skip.
    }
    idx += 1
  }

  // After options, the next token should be the destination.
  guard idx < tokens.count else { return nil }
  let destination = tokens[idx]
  let (destUser, destHost) = splitUserAtHost(destination)
  guard let destHost, !destHost.isEmpty else { return nil }

  // Reject obvious non-host destinations.
  if destHost.contains("/") { return nil }
  if destHost.contains("$") { return nil }

  // `-l user` wins if both forms were given; otherwise the `user@` form.
  user = user ?? destUser
  hostname = destHost

  return RawObservation(
    raw: command,
    user: user?.isEmpty == true ? nil : user,
    hostname: hostname ?? destHost,
    port: port,
    identityFile: identityFile,
    timestamp: timestamp
  )
}

/// Flags that consume the next argument. Mirrors OpenSSH's `ssh(1)` man
/// page; we don't need to be exhaustive — unknown flags just cause the
/// parser to drop the line, which is fine.
private nonisolated let sshFlagsTakingArgument: Set<String> = [
  "-B", "-b", "-c", "-D", "-E", "-e", "-F", "-I", "-J", "-L", "-m", "-O",
  "-P", "-Q", "-R", "-S", "-W", "-w",
]

/// OpenSSH's `-o key=value` syntax overlaps with the named flags. Only a
/// few keys matter for our purposes; the rest are ignored.
nonisolated func parseSSHOptionFlag(
  _ option: String,
  into user: inout String?,
  port: inout Int?,
  identityFile: inout String?
) {
  let parts = option.split(separator: "=", maxSplits: 1).map(String.init)
  guard parts.count == 2 else { return }
  let key = parts[0].lowercased()
  let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
  switch key {
  case "user":
    if !value.isEmpty { user = value }
  case "port":
    if let p = Int(value) { port = p }
  case "identityfile":
    if !value.isEmpty { identityFile = value }
  default:
    break
  }
}

private nonisolated func splitUserAtHost(_ destination: String) -> (String?, String?) {
  guard let at = destination.firstIndex(of: "@") else {
    return (nil, destination.isEmpty ? nil : destination)
  }
  let user = String(destination[..<at])
  let host = String(destination[destination.index(after: at)...])
  return (user.isEmpty ? nil : user, host)
}

/// Finds the first `ssh` token, stepping past shell wrappers we know
/// don't change identity. Returns `nil` if the command doesn't look
/// like a straightforward ssh invocation.
nonisolated func locateSSHToken(in tokens: [String]) -> Int? {
  var idx = 0
  while idx < tokens.count {
    let token = tokens[idx]
    if token == "ssh" { return idx }
    // Accept absolute / nearby paths to ssh: `/usr/bin/ssh`, `./ssh`.
    if token.hasSuffix("/ssh") { return idx }
    // Skip harmless wrappers. `sudo` / `doas` would change the user, so
    // we deliberately don't skip those — better to ignore the line than
    // import a host the user would never connect to as themselves.
    if idx == 0, leadingWrappers.contains(token) {
      idx += 1
      continue
    }
    // `VAR=value ssh …` inline-env prefix. Tokens that contain an `=`
    // before any `/` look like env assignments.
    if idx == 0, isEnvAssignmentToken(token) {
      idx += 1
      continue
    }
    return nil
  }
  return nil
}

private nonisolated let leadingWrappers: Set<String> = [
  "time", "nice", "nohup", "command",
]

private nonisolated func isEnvAssignmentToken(_ token: String) -> Bool {
  guard let eq = token.firstIndex(of: "=") else { return false }
  let key = token[..<eq]
  guard !key.isEmpty else { return false }
  return key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
}

// MARK: - Tokenization

/// Minimal shell tokenizer: splits on whitespace while respecting single
/// and double quotes. Doesn't attempt variable expansion, command
/// substitution, or heredocs — candidates that would require any of
/// those get dropped later because we can't resolve them statically.
nonisolated func shellTokens(from command: String) -> [String] {
  var tokens: [String] = []
  var current = ""
  var quote: Character? = nil
  var escape = false

  for char in command {
    if escape {
      current.append(char)
      escape = false
      continue
    }
    if char == "\\" {
      escape = true
      continue
    }
    if let q = quote {
      if char == q {
        quote = nil
      } else {
        current.append(char)
      }
      continue
    }
    if char == "\"" || char == "'" {
      quote = char
      continue
    }
    if char.isWhitespace {
      if !current.isEmpty {
        tokens.append(current)
        current = ""
      }
      continue
    }
    current.append(char)
  }
  if !current.isEmpty { tokens.append(current) }
  return tokens
}

// MARK: - Rollup

/// Collapses raw observations into unique candidates. Dedupe key is the
/// full `(user, hostname, port, identityFile)` tuple — identical targets
/// invoked with the same flags are merged, same target with different
/// identity files produce separate candidates so the user can pick.
nonisolated func rollUp(observations: [RawObservation]) -> [SSHHistoryCandidate] {
  struct Key: Hashable {
    let user: String?
    let hostname: String
    let port: Int?
    let identityFile: String?
  }
  var buckets: [Key: (raw: String, count: Int, lastSeen: Date?)] = [:]
  for obs in observations {
    let key = Key(
      user: obs.user, hostname: obs.hostname, port: obs.port,
      identityFile: obs.identityFile
    )
    if var existing = buckets[key] {
      existing.count += 1
      if let newStamp = obs.timestamp {
        if let old = existing.lastSeen {
          existing.lastSeen = max(old, newStamp)
        } else {
          existing.lastSeen = newStamp
        }
      }
      buckets[key] = existing
    } else {
      buckets[key] = (obs.raw, 1, obs.timestamp)
    }
  }
  let candidates = buckets.map { key, bucket in
    SSHHistoryCandidate(
      raw: bucket.raw,
      user: key.user,
      hostname: key.hostname,
      port: key.port,
      identityFile: key.identityFile,
      timesSeen: bucket.count,
      lastSeenAt: bucket.lastSeen
    )
  }
  return candidates.sorted { lhs, rhs in
    switch (lhs.lastSeenAt, rhs.lastSeenAt) {
    case (let l?, let r?):
      return l > r
    case (.some, nil):
      return true
    case (nil, .some):
      return false
    case (nil, nil):
      if lhs.timesSeen != rhs.timesSeen { return lhs.timesSeen > rhs.timesSeen }
      return lhs.hostname < rhs.hostname
    }
  }
}
