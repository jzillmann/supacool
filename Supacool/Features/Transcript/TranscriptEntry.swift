import Foundation

/// One row in a session transcript. Discriminated union: either something
/// the user sent toward the PTY, or a snapshot of what the terminal was
/// showing at an idle moment.
///
/// **Why two shapes instead of one raw byte stream?** Ghostty exposes no
/// byte-level PTY-write callback to Swift — we can only (a) intercept the
/// Swift-side calls that push bytes *in* (keystrokes, paste, programmatic
/// `sendText`), and (b) read the current rendered surface on demand. So
/// input is logged byte-accurate; output is logged as post-render plaintext
/// snapshots at meaningful moments (busy→idle edges, command-finished).
///
/// For Claude sessions there's also a richer native transcript at
/// `~/.claude/projects/<hashed>/<session-id>.jsonl` — see
/// `SessionReferenceScannerLive`. This enum is the *unified*, agent-agnostic
/// view that works for codex / shell sessions too.
///
/// Codable is hand-rolled per [docs/agent-guides/persistence.md] —
/// synthesized decoding silently wipes user data the instant a new field
/// lands, which has bitten us before. Mirrors the shape of
/// `SessionReference` (discriminant + payload keys).
nonisolated enum TranscriptEntry: Codable, Equatable, Hashable, Sendable {
  /// Bytes the user pushed toward the PTY — keystrokes, paste, programmatic
  /// `sendText` (initial prompt injection, blocking-script replies).
  /// Skipped entirely while `secureInput` is ON so sudo / SSH passwords
  /// never land in the transcript file.
  case input(text: String, at: Date)

  /// Plaintext rendered surface at an idle boundary. `delta` is the suffix
  /// new since the previous snapshot — what the agent "said this turn." A
  /// reader that only cares about turns can ignore `fullText` and stream
  /// `delta`; a reader that wants grep-able archive uses `fullText`.
  case outputTurn(fullText: String, delta: String, at: Date)

  enum DiscriminantKeys: String, CodingKey { case kind }
  enum InputKeys: String, CodingKey { case text, at }
  enum OutputKeys: String, CodingKey { case fullText, delta, at }

  init(from decoder: Decoder) throws {
    let d = try decoder.container(keyedBy: DiscriminantKeys.self)
    let kind = try d.decode(String.self, forKey: .kind)
    switch kind {
    case "input":
      let c = try decoder.container(keyedBy: InputKeys.self)
      let text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
      let at = try c.decodeIfPresent(Date.self, forKey: .at) ?? Date()
      self = .input(text: text, at: at)
    case "outputTurn":
      let c = try decoder.container(keyedBy: OutputKeys.self)
      let fullText = try c.decodeIfPresent(String.self, forKey: .fullText) ?? ""
      let delta = try c.decodeIfPresent(String.self, forKey: .delta) ?? ""
      let at = try c.decodeIfPresent(Date.self, forKey: .at) ?? Date()
      self = .outputTurn(fullText: fullText, delta: delta, at: at)
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .kind,
        in: d,
        debugDescription: "Unknown TranscriptEntry kind: \(kind)"
      )
    }
  }

  func encode(to encoder: Encoder) throws {
    switch self {
    case .input(let text, let at):
      var d = encoder.container(keyedBy: DiscriminantKeys.self)
      try d.encode("input", forKey: .kind)
      var c = encoder.container(keyedBy: InputKeys.self)
      try c.encode(text, forKey: .text)
      try c.encode(at, forKey: .at)
    case .outputTurn(let fullText, let delta, let at):
      var d = encoder.container(keyedBy: DiscriminantKeys.self)
      try d.encode("outputTurn", forKey: .kind)
      var c = encoder.container(keyedBy: OutputKeys.self)
      try c.encode(fullText, forKey: .fullText)
      try c.encode(delta, forKey: .delta)
      try c.encode(at, forKey: .at)
    }
  }

  var timestamp: Date {
    switch self {
    case .input(_, let at): return at
    case .outputTurn(_, _, let at): return at
    }
  }
}

/// Computes the suffix of `newText` that's new relative to `previousText`,
/// assuming the scrollback is append-mostly (which `ghostty_surface_read_text`
/// with `GHOSTTY_POINT_SURFACE` effectively is — the buffer only grows, with
/// trim-at-top when scrollback overflows).
///
/// Strategy: find the longest common prefix, return everything after. If the
/// buffer got trimmed at the top (previous lines scrolled past the scrollback
/// cap), the common prefix will be shorter than `previousText`, and we'll
/// return a delta that includes some already-seen content — which is the
/// correct behavior: we'd rather re-emit than drop.
nonisolated enum TranscriptDelta {
  static func compute(previous: String, next: String) -> String {
    guard !previous.isEmpty else { return next }
    // Walk by Character to stay Unicode-correct (emoji, combining marks, etc.)
    var prevIter = previous.makeIterator()
    var nextIter = next.makeIterator()
    var commonPrefixCount = 0
    while let p = prevIter.next(), let n = nextIter.next(), p == n {
      commonPrefixCount += 1
    }
    if commonPrefixCount >= previous.count {
      // `previous` is fully contained in `next` — the suffix is the delta.
      return String(next.dropFirst(commonPrefixCount))
    }
    // Scrollback trim: we diverged inside what we thought was `previous`.
    // Return the whole `next` rather than attempt a realignment.
    return next
  }
}
