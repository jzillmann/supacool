import Foundation

/// One row in a session transcript. Discriminated union covering raw PTY
/// traffic (user input, rendered output snapshots) and structured session
/// events (hook payloads, state transitions, lifecycle edges, auto-observer
/// and background-inference decisions).
///
/// **Two shapes for the raw stream, many shapes for the events.** Ghostty
/// exposes no byte-level PTY-write callback to Swift — we can only
/// (a) intercept the Swift-side calls that push bytes *in* (keystrokes,
/// paste, programmatic `sendText`), and (b) read the current rendered
/// surface on demand. Input is logged byte-accurate; output is logged as
/// post-render plaintext snapshots at meaningful moments (busy→idle edges).
/// Everything else — hook arrivals, awaiting-input flips, lifecycle edges,
/// auto-observer decisions — is a structured event with its own payload.
///
/// For Claude sessions there's also a richer native transcript at
/// `~/.claude/projects/<hashed>/<session-id>.jsonl` — see
/// `SessionReferenceScannerLive`. This enum is the *unified*, agent-agnostic
/// view that works for codex / shell sessions too.
///
/// **Multi-surface note.** One `AgentSession` owns one Ghostty tab, which can
/// host multiple surfaces (splits). The trace file is keyed by tab; events
/// that originate per-surface carry `surfaceID` so readers can reconstruct
/// which pane emitted what.
///
/// **Known gap (v1).** Session-less background inference calls — e.g.
/// branch-name generation from the New Terminal sheet before a session
/// exists — aren't traced. They have no session file to write to. A future
/// `_global.jsonl` sink could absorb them.
///
/// Codable is hand-rolled per [docs/agent-guides/persistence.md] —
/// synthesized decoding silently wipes user data the instant a new field
/// lands, which has bitten us before. Every case uses
/// `decodeIfPresent ?? default` for every field. Mirrors the shape of
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

  /// Raw `onBusy` hook payload. One entry per socket message — both the
  /// active=true edge (agent started) and active=false edge (agent idle).
  /// `pid` is nil for pre-upgrade hook clients that don't report it.
  case hookBusy(active: Bool, pid: Int32?, surfaceID: UUID, at: Date)

  /// Raw `onNotification` hook payload. Emitted for every notification
  /// regardless of classifier verdict — informational pings, idle
  /// reminders, and permission prompts all land here so we can audit
  /// misclassifications after the fact.
  case hookEvent(
    agent: String,
    event: String,
    title: String?,
    body: String?,
    sessionID: String?,
    awaitingClassifierVerdict: Bool,
    surfaceID: UUID,
    at: Date
  )

  /// Awaiting-input state flip. `source` is a free-form string so adding
  /// new promotion / demotion reasons later doesn't break the schema:
  /// `"hook"` | `"screen-fallback"` | `"ttl-expired"` |
  /// `"activity-resumed"` | `"pid-gone"` | `"tab-closed"`.
  case awaitingInputChanged(active: Bool, source: String, surfaceID: UUID?, at: Date)

  /// Session-level lifecycle edge. `kind` is stringly-typed for the same
  /// forward-compat reason as `source` above. Initial set: `"created"` |
  /// `"parked"` | `"resumed"` | `"removed"` | `"detached"` |
  /// `"interrupted"`. `context` carries a short free-form reason (e.g. the
  /// agent name on creation, or the trigger for a removal).
  case sessionLifecycle(kind: String, context: String?, at: Date)

  /// AutoObserverClient decision — fires once per `decide` call regardless
  /// of outcome. `layer` is `"regex"` (layer-1 pattern match) or
  /// `"inference"` (layer-2 Claude call). `decision` is the typed string
  /// or nil when the observer chose to skip. `inferenceDurationMs` is
  /// populated only when `layer == "inference"`.
  case autoObserver(
    fingerprintHash: String,
    userInstructions: String?,
    layer: String,
    decision: String?,
    inferenceDurationMs: Int?,
    at: Date
  )

  /// BackgroundInferenceClient call that happened in a session context.
  /// Prompt / result previews are truncated at the call site (~500 chars)
  /// so the trace file doesn't balloon on long prompts. `error` is the
  /// `localizedDescription` of any thrown error, or nil on success.
  case backgroundInference(
    purpose: String,
    mode: String,
    promptPreview: String,
    resultPreview: String?,
    error: String?,
    durationMs: Int,
    at: Date
  )

  // MARK: - Codable

  enum DiscriminantKeys: String, CodingKey { case kind }
  private enum InputKeys: String, CodingKey { case text, at }
  private enum OutputKeys: String, CodingKey { case fullText, delta, at }
  private enum HookBusyKeys: String, CodingKey { case active, pid, surfaceID, at }
  private enum HookEventKeys: String, CodingKey {
    case agent, event, title, body, sessionID, awaitingClassifierVerdict, surfaceID, at
  }
  private enum AwaitingKeys: String, CodingKey { case active, source, surfaceID, at }
  private enum LifecycleKeys: String, CodingKey { case lifecycleKind, context, at }
  private enum AutoObserverKeys: String, CodingKey {
    case fingerprintHash, userInstructions, layer, decision, inferenceDurationMs, at
  }
  private enum BackgroundInferenceKeys: String, CodingKey {
    case purpose, mode, promptPreview, resultPreview, error, durationMs, at
  }

  init(from decoder: Decoder) throws {
    let d = try decoder.container(keyedBy: DiscriminantKeys.self)
    let kind = try d.decode(String.self, forKey: .kind)
    switch kind {
    case "input":
      let c = try decoder.container(keyedBy: InputKeys.self)
      self = .input(
        text: try c.decodeIfPresent(String.self, forKey: .text) ?? "",
        at: try c.decodeIfPresent(Date.self, forKey: .at) ?? Date()
      )
    case "outputTurn":
      let c = try decoder.container(keyedBy: OutputKeys.self)
      self = .outputTurn(
        fullText: try c.decodeIfPresent(String.self, forKey: .fullText) ?? "",
        delta: try c.decodeIfPresent(String.self, forKey: .delta) ?? "",
        at: try c.decodeIfPresent(Date.self, forKey: .at) ?? Date()
      )
    case "hookBusy":
      let c = try decoder.container(keyedBy: HookBusyKeys.self)
      self = .hookBusy(
        active: try c.decodeIfPresent(Bool.self, forKey: .active) ?? false,
        pid: try c.decodeIfPresent(Int32.self, forKey: .pid),
        surfaceID: try c.decodeIfPresent(UUID.self, forKey: .surfaceID) ?? UUID(),
        at: try c.decodeIfPresent(Date.self, forKey: .at) ?? Date()
      )
    case "hookEvent":
      let c = try decoder.container(keyedBy: HookEventKeys.self)
      self = .hookEvent(
        agent: try c.decodeIfPresent(String.self, forKey: .agent) ?? "",
        event: try c.decodeIfPresent(String.self, forKey: .event) ?? "",
        title: try c.decodeIfPresent(String.self, forKey: .title),
        body: try c.decodeIfPresent(String.self, forKey: .body),
        sessionID: try c.decodeIfPresent(String.self, forKey: .sessionID),
        awaitingClassifierVerdict: try c.decodeIfPresent(
          Bool.self, forKey: .awaitingClassifierVerdict
        ) ?? false,
        surfaceID: try c.decodeIfPresent(UUID.self, forKey: .surfaceID) ?? UUID(),
        at: try c.decodeIfPresent(Date.self, forKey: .at) ?? Date()
      )
    case "awaitingInputChanged":
      let c = try decoder.container(keyedBy: AwaitingKeys.self)
      self = .awaitingInputChanged(
        active: try c.decodeIfPresent(Bool.self, forKey: .active) ?? false,
        source: try c.decodeIfPresent(String.self, forKey: .source) ?? "",
        surfaceID: try c.decodeIfPresent(UUID.self, forKey: .surfaceID),
        at: try c.decodeIfPresent(Date.self, forKey: .at) ?? Date()
      )
    case "sessionLifecycle":
      let c = try decoder.container(keyedBy: LifecycleKeys.self)
      self = .sessionLifecycle(
        kind: try c.decodeIfPresent(String.self, forKey: .lifecycleKind) ?? "",
        context: try c.decodeIfPresent(String.self, forKey: .context),
        at: try c.decodeIfPresent(Date.self, forKey: .at) ?? Date()
      )
    case "autoObserver":
      let c = try decoder.container(keyedBy: AutoObserverKeys.self)
      self = .autoObserver(
        fingerprintHash: try c.decodeIfPresent(String.self, forKey: .fingerprintHash) ?? "",
        userInstructions: try c.decodeIfPresent(String.self, forKey: .userInstructions),
        layer: try c.decodeIfPresent(String.self, forKey: .layer) ?? "",
        decision: try c.decodeIfPresent(String.self, forKey: .decision),
        inferenceDurationMs: try c.decodeIfPresent(Int.self, forKey: .inferenceDurationMs),
        at: try c.decodeIfPresent(Date.self, forKey: .at) ?? Date()
      )
    case "backgroundInference":
      let c = try decoder.container(keyedBy: BackgroundInferenceKeys.self)
      self = .backgroundInference(
        purpose: try c.decodeIfPresent(String.self, forKey: .purpose) ?? "",
        mode: try c.decodeIfPresent(String.self, forKey: .mode) ?? "",
        promptPreview: try c.decodeIfPresent(String.self, forKey: .promptPreview) ?? "",
        resultPreview: try c.decodeIfPresent(String.self, forKey: .resultPreview),
        error: try c.decodeIfPresent(String.self, forKey: .error),
        durationMs: try c.decodeIfPresent(Int.self, forKey: .durationMs) ?? 0,
        at: try c.decodeIfPresent(Date.self, forKey: .at) ?? Date()
      )
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
    case .hookBusy(let active, let pid, let surfaceID, let at):
      var d = encoder.container(keyedBy: DiscriminantKeys.self)
      try d.encode("hookBusy", forKey: .kind)
      var c = encoder.container(keyedBy: HookBusyKeys.self)
      try c.encode(active, forKey: .active)
      try c.encodeIfPresent(pid, forKey: .pid)
      try c.encode(surfaceID, forKey: .surfaceID)
      try c.encode(at, forKey: .at)
    case .hookEvent(
      let agent, let event, let title, let body, let sessionID,
      let awaitingClassifierVerdict, let surfaceID, let at
    ):
      var d = encoder.container(keyedBy: DiscriminantKeys.self)
      try d.encode("hookEvent", forKey: .kind)
      var c = encoder.container(keyedBy: HookEventKeys.self)
      try c.encode(agent, forKey: .agent)
      try c.encode(event, forKey: .event)
      try c.encodeIfPresent(title, forKey: .title)
      try c.encodeIfPresent(body, forKey: .body)
      try c.encodeIfPresent(sessionID, forKey: .sessionID)
      try c.encode(awaitingClassifierVerdict, forKey: .awaitingClassifierVerdict)
      try c.encode(surfaceID, forKey: .surfaceID)
      try c.encode(at, forKey: .at)
    case .awaitingInputChanged(let active, let source, let surfaceID, let at):
      var d = encoder.container(keyedBy: DiscriminantKeys.self)
      try d.encode("awaitingInputChanged", forKey: .kind)
      var c = encoder.container(keyedBy: AwaitingKeys.self)
      try c.encode(active, forKey: .active)
      try c.encode(source, forKey: .source)
      try c.encodeIfPresent(surfaceID, forKey: .surfaceID)
      try c.encode(at, forKey: .at)
    case .sessionLifecycle(let kind, let context, let at):
      var d = encoder.container(keyedBy: DiscriminantKeys.self)
      try d.encode("sessionLifecycle", forKey: .kind)
      var c = encoder.container(keyedBy: LifecycleKeys.self)
      try c.encode(kind, forKey: .lifecycleKind)
      try c.encodeIfPresent(context, forKey: .context)
      try c.encode(at, forKey: .at)
    case .autoObserver(
      let fingerprintHash, let userInstructions, let layer,
      let decision, let inferenceDurationMs, let at
    ):
      var d = encoder.container(keyedBy: DiscriminantKeys.self)
      try d.encode("autoObserver", forKey: .kind)
      var c = encoder.container(keyedBy: AutoObserverKeys.self)
      try c.encode(fingerprintHash, forKey: .fingerprintHash)
      try c.encodeIfPresent(userInstructions, forKey: .userInstructions)
      try c.encode(layer, forKey: .layer)
      try c.encodeIfPresent(decision, forKey: .decision)
      try c.encodeIfPresent(inferenceDurationMs, forKey: .inferenceDurationMs)
      try c.encode(at, forKey: .at)
    case .backgroundInference(
      let purpose, let mode, let promptPreview, let resultPreview,
      let error, let durationMs, let at
    ):
      var d = encoder.container(keyedBy: DiscriminantKeys.self)
      try d.encode("backgroundInference", forKey: .kind)
      var c = encoder.container(keyedBy: BackgroundInferenceKeys.self)
      try c.encode(purpose, forKey: .purpose)
      try c.encode(mode, forKey: .mode)
      try c.encode(promptPreview, forKey: .promptPreview)
      try c.encodeIfPresent(resultPreview, forKey: .resultPreview)
      try c.encodeIfPresent(error, forKey: .error)
      try c.encode(durationMs, forKey: .durationMs)
      try c.encode(at, forKey: .at)
    }
  }

  var timestamp: Date {
    switch self {
    case .input(_, let at): return at
    case .outputTurn(_, _, let at): return at
    case .hookBusy(_, _, _, let at): return at
    case .hookEvent(_, _, _, _, _, _, _, let at): return at
    case .awaitingInputChanged(_, _, _, let at): return at
    case .sessionLifecycle(_, _, let at): return at
    case .autoObserver(_, _, _, _, _, let at): return at
    case .backgroundInference(_, _, _, _, _, _, let at): return at
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
