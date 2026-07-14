import Darwin
import Foundation
import Observation
import Sharing
import SwiftUI

private let terminalLogger = SupaLogger("Terminal")
private let awaitingInputTTLDefault: Duration = .seconds(8)
/// How long an `awaitingInput` signal must stay active before the chip
/// is actually shown. Wider than the off-debounce so Codex's
/// `PermissionRequest → PreToolUse` auto-approve round-trips (~200–500ms)
/// don't produce a visible blink between "In Progress" and "Wants Input".
private let awaitingInputTransitionOnDebounceDefault: Duration = .milliseconds(750)
/// Mirror debounce for turning the chip off. Kept tight so the card
/// responds quickly when the user actually answers a prompt.
private let awaitingInputOffDebounceDefault: Duration = .milliseconds(250)
private let awaitingInputActivityPollIntervalDefault: Duration = .seconds(1)
private let awaitingInputFingerprintLineCount = 12
private let awaitingInputPromptStableSamples = 2
/// Consecutive scan ticks the agent's interrupt hint may be missing before
/// the screen-working lease drops. Absorbs the odd tick where the footer is
/// mid-repaint, so the card doesn't strobe between Working and Waiting.
private let screenWorkingMissGraceDefault = 3
/// Consecutive scan ticks a tab may show neither a hook signal nor an
/// interrupt hint before it stops being screen-scanned for working state.
/// At the 1s poll interval that's ~2 minutes of confirmed quiet. Bounds the
/// per-tick screen reads to tabs that plausibly have a live agent, so a
/// board full of long-idle cards costs nothing; the next hook (or the user
/// hitting Enter) re-arms the scan via `noteAgentSignal`.
private let screenWorkingQuietTickLimitDefault = 120
private let agentPIDSweepIntervalDefault: Duration = .seconds(30)
private let ownedProcessRefreshIntervalDefault: Duration = .seconds(60)
private let optimisticBusyTTLDefault: Duration = .seconds(15)
nonisolated private let deferredWorkFallbackTTLDefault: Duration = .seconds(15 * 60)
nonisolated private let deferredWorkLeaseBufferDefault: Duration = .seconds(90)
/// Window between session creation and the first expected agent hook
/// event. When this elapses without any `hookBusy`/`hookEvent` landing
/// for a tab that received a submitted initial input, the manager
/// force-snapshots the current screen into the transcript and writes a
/// synthetic `sessionLifecycle("firstHookDeadman")` event so a debug
/// agent has something to look at when the trace would otherwise be
/// silent. `optimisticBusyTTL` already keeps the board card honest;
/// this exists purely to leave post-mortem evidence in the trace.
private let firstHookDeadmanDelayDefault: Duration = .seconds(10)
/// Consecutive agent-PID sweeps an alive-but-silent busy agent may go —
/// no intervening busy hook AND a byte-stable screen — before the stuck-
/// busy watchdog clears its latch. At the 30s default sweep interval this
/// is ~90s of confirmed silence. Guards the case where an agent (observed
/// with codex, trace DF73B24A…) ends its turn but drops *every* end-of-turn
/// edge — no `busy=0`, no `Stop` notification — while its process stays
/// alive: the PID-death sweep skips it (alive), the Stop/awaiting paths
/// never fire (no hook), and hooked tabs are excluded from the screen
/// fallback, so nothing else recovers the latch. See `reconcileStuckBusy`.
private let stuckBusyStaleSweepThresholdDefault = 3

private let defaultIsProcessAlive: @Sendable (Int32) -> Bool = { pid in
  // `kill(pid, 0)` returns 0 when the process exists (signal-less ping).
  // ESRCH → process gone. EPERM → exists but we can't signal it; still alive.
  if kill(pid, 0) == 0 { return true }
  return errno != ESRCH
}

@MainActor
@Observable
final class WorktreeTerminalManager {
  private struct AwaitingInputTracker {
    let worktreeID: Worktree.ID
    var rawActive = false
    var presented = false
    var lastScreenFingerprint: String?
  }

  private struct AwaitingInputPromptCandidate {
    let worktreeID: Worktree.ID
    var fingerprint: String
    var stableSampleCount = 1
  }

  private struct DeferredWorkTracker {
    let worktreeID: Worktree.ID
  }

  private struct OptimisticBusyTracker {
    let worktreeID: Worktree.ID
  }

  /// Supacool-only. Per-tab lease asserting "the agent's own UI says it is
  /// working", set from the interrupt hint it paints for the whole turn.
  /// This is the only busy signal that survives a hook-silent stretch of
  /// pure model thinking. See `isAgentWorkingScreen`.
  private struct ScreenWorkingTracker {
    let worktreeID: Worktree.ID
    /// Consecutive scan ticks the hint has been absent. Cleared at
    /// `screenWorkingMissGrace`; see `relaxScreenWorking`.
    var missedSamples = 0
  }

  /// Supacool-only. Per-tab registration of the agent process PID so a
  /// background sweep can clear stale busy/awaiting state if the agent
  /// crashes (SIGKILL, OOM) before a clean `Stop`/`SessionEnd` hook fires.
  private struct AgentPIDRegistration: Sendable {
    let worktreeID: Worktree.ID
    let surfaceID: UUID
    let pid: Int32
    /// Consecutive liveness sweeps survived with no intervening busy hook
    /// and an unchanged screen. Resets to 0 every time a busy hook
    /// re-registers this PID (the registration is recreated wholesale).
    /// Drives the stuck-busy watchdog in `reconcileStuckBusy`.
    var staleSweeps = 0
    /// Screen fingerprint captured at the previous sweep. A change between
    /// sweeps means the agent is still emitting output (so: not stuck); a
    /// fingerprint stable across the staleness window is the idle signal
    /// that lets the watchdog distinguish a dropped end-of-turn edge from a
    /// legitimately long, quiet tool run.
    var lastFingerprint: String?
  }

  private let runtime: GhosttyRuntime
  private let sleep: @Sendable (Duration) async throws -> Void
  private let awaitingInputTTL: Duration
  private let awaitingInputTransitionOnDebounce: Duration
  private let awaitingInputTransitionOffDebounce: Duration
  private let awaitingInputActivityPollInterval: Duration
  private let agentPIDSweepInterval: Duration
  private let ownedProcessRefreshInterval: Duration
  private let optimisticBusyTTL: Duration
  private let deferredWorkFallbackTTL: Duration
  private let deferredWorkLeaseBuffer: Duration
  private let firstHookDeadmanDelay: Duration
  private let stuckBusyStaleSweepThreshold: Int
  private let screenWorkingMissGrace: Int
  private let screenWorkingQuietTickLimit: Int
  private let isProcessAlive: @Sendable (Int32) -> Bool
  /// Tracker that attributes orphaned (`ppid == 1`) processes whose cwd
  /// is under `~/.supacool/repos/` to their owning worktree. Refresh is
  /// non-destructive; `release(worktreePath:)` is what actually kills.
  /// Optional so tests can disable the live OS scan; production wiring
  /// in `SupacoolApp` injects a real instance.
  private let ownedProcessTracker: WorktreeOwnedProcessTracker?
  private var ownedProcessRefreshTickCount: Int = 0
  private let readScreenContentsOverride: ((Worktree.ID, TerminalTabID) -> String?)?
  private(set) var socketServer: AgentHookSocketServer?
  private var states: [Worktree.ID: WorktreeTerminalState] = [:]
  /// Supacool-only. Per-tab awaiting-input tracking. The hook signal is
  /// treated as a soft lease: it expires unless reaffirmed, and any resumed
  /// terminal output clears it after a short stabilization window.
  private var awaitingInputByTab: [UUID: AwaitingInputTracker] = [:]
  private var awaitingInputExpiryTasks: [UUID: Task<Void, Never>] = [:]
  private var awaitingInputDebounceTasks: [UUID: Task<Void, Never>] = [:]
  private var awaitingInputActivityTasks: [UUID: Task<Void, Never>] = [:]
  private var awaitingInputPromptCandidates: [UUID: AwaitingInputPromptCandidate] = [:]
  private var awaitingInputPromptScanTask: Task<Void, Never>?
  private var awaitingInputPromptScanTickCount: Int = 0
  private var deferredWorkByTab: [UUID: DeferredWorkTracker] = [:]
  private var deferredWorkExpiryTasks: [UUID: Task<Void, Never>] = [:]
  private var optimisticBusyByTab: [UUID: OptimisticBusyTracker] = [:]
  private var optimisticBusyExpiryTasks: [UUID: Task<Void, Never>] = [:]
  /// Supacool-only. Tabs whose agent is currently painting its interrupt
  /// hint. Refreshed by the 1s screen scan; no expiry task — the scan is
  /// the clock.
  private var screenWorkingByTab: [UUID: ScreenWorkingTracker] = [:]
  /// Consecutive scan ticks a tab has produced neither a hook signal nor an
  /// interrupt hint. Past `screenWorkingQuietTickLimit` the tab drops out of
  /// the working-screen scan until a hook or a submit wakes it.
  private var screenWorkingQuietTicks: [UUID: Int] = [:]
  /// Per-tab one-shot timer that snapshots the surface and writes a
  /// synthetic lifecycle event when no agent hook lands within
  /// `firstHookDeadmanDelay`. Cancelled the moment any hook is observed
  /// or the tab tree disappears. Keyed by raw tab UUID so cancellation
  /// from `markInitialAgentEventObserved` is O(1).
  private var firstHookDeadmanTasks: [UUID: Task<Void, Never>] = [:]
  #if DEBUG
    /// Test-only counter incremented every time the deadman actually
    /// fires (vs. being cancelled). Exposed because the recorder's
    /// disk-writing side effect is hard to observe synchronously and
    /// the existing test suite mocks behavior, not files.
    private(set) var firstHookDeadmanFireCount: Int = 0
  #endif
  /// Per-tab PID registry, keyed by PID so a surface running multiple
  /// agents (pi spawning codex on the same PTY) keeps a registration for
  /// each. Without per-PID keying the inner agent's registration would
  /// overwrite the outer's, leaving the sweep blind to pi when codex
  /// finishes cleanly.
  private var agentPIDByTab: [UUID: [Int32: AgentPIDRegistration]] = [:]
  private var notificationsEnabled = true
  private var lastNotificationIndicatorCount: Int?
  private var eventContinuation: AsyncStream<TerminalClient.Event>.Continuation?
  private var pendingEvents: [TerminalClient.Event] = []
  @ObservationIgnored
  @Shared(.agentSessions) private var agentSessions: [AgentSession]
  var selectedWorktreeID: Worktree.ID?
  var saveLayoutSnapshot: ((Worktree.ID, TerminalLayoutSnapshot?) -> Void)?
  var loadLayoutSnapshot: ((Worktree.ID) -> TerminalLayoutSnapshot?)?
  var loadSavedLayoutSnapshot: ((Worktree.ID) -> TerminalLayoutSnapshot?)?

  init<C: Clock<Duration>>(
    runtime: GhosttyRuntime,
    socketServer: AgentHookSocketServer? = nil,
    awaitingInputTTL: Duration = awaitingInputTTLDefault,
    awaitingInputTransitionOnDebounce: Duration = awaitingInputTransitionOnDebounceDefault,
    awaitingInputTransitionOffDebounce: Duration = awaitingInputOffDebounceDefault,
    awaitingInputActivityPollInterval: Duration = awaitingInputActivityPollIntervalDefault,
    agentPIDSweepInterval: Duration = agentPIDSweepIntervalDefault,
    ownedProcessRefreshInterval: Duration = ownedProcessRefreshIntervalDefault,
    optimisticBusyTTL: Duration = optimisticBusyTTLDefault,
    deferredWorkFallbackTTL: Duration = deferredWorkFallbackTTLDefault,
    deferredWorkLeaseBuffer: Duration = deferredWorkLeaseBufferDefault,
    firstHookDeadmanDelay: Duration = firstHookDeadmanDelayDefault,
    stuckBusyStaleSweepThreshold: Int = stuckBusyStaleSweepThresholdDefault,
    screenWorkingMissGrace: Int = screenWorkingMissGraceDefault,
    screenWorkingQuietTickLimit: Int = screenWorkingQuietTickLimitDefault,
    isProcessAlive: @escaping @Sendable (Int32) -> Bool = defaultIsProcessAlive,
    ownedProcessTracker: WorktreeOwnedProcessTracker? = nil,
    startPromptScreenScanning: Bool = true,
    clock: C = ContinuousClock(),
    readScreenContents: ((Worktree.ID, TerminalTabID) -> String?)? = nil
  ) {
    self.runtime = runtime
    self.awaitingInputTTL = awaitingInputTTL
    self.awaitingInputTransitionOnDebounce = awaitingInputTransitionOnDebounce
    self.awaitingInputTransitionOffDebounce = awaitingInputTransitionOffDebounce
    self.awaitingInputActivityPollInterval = awaitingInputActivityPollInterval
    self.agentPIDSweepInterval = agentPIDSweepInterval
    self.ownedProcessRefreshInterval = ownedProcessRefreshInterval
    self.optimisticBusyTTL = optimisticBusyTTL
    self.deferredWorkFallbackTTL = deferredWorkFallbackTTL
    self.deferredWorkLeaseBuffer = deferredWorkLeaseBuffer
    self.firstHookDeadmanDelay = firstHookDeadmanDelay
    self.stuckBusyStaleSweepThreshold = stuckBusyStaleSweepThreshold
    self.screenWorkingMissGrace = screenWorkingMissGrace
    self.screenWorkingQuietTickLimit = screenWorkingQuietTickLimit
    self.isProcessAlive = isProcessAlive
    self.ownedProcessTracker = ownedProcessTracker
    self.sleep = { duration in
      try await clock.sleep(for: duration)
    }
    self.readScreenContentsOverride = readScreenContents
    if startPromptScreenScanning {
      startAwaitingInputPromptScreenScanning()
    }
    let resolvedServer = socketServer ?? AgentHookSocketServer()
    guard resolvedServer.socketPath != nil else {
      self.socketServer = nil
      terminalLogger.warning("Agent hook socket server unavailable")
      return
    }
    self.socketServer = resolvedServer
    configureSocketServer(resolvedServer)
  }

  private func configureSocketServer(_ server: AgentHookSocketServer) {
    configureBusyHandler(server)
    configureNotificationHandler(server)
  }

  private func configureBusyHandler(_ server: AgentHookSocketServer) {
    server.onBusy = { [weak self] worktreeID, tabID, surfaceID, active, pid in
      let decoded = worktreeID.removingPercentEncoding ?? worktreeID
      let wrappedTabID = TerminalTabID(rawValue: tabID)
      terminalLogger.debug(
        "Hook busy: worktree=\(decoded) tab=\(tabID) surface=\(surfaceID) "
          + "active=\(active) pid=\(pid.map(String.init) ?? "nil")"
      )
      TranscriptRecorder.shared.append(
        event: .hookBusy(active: active, pid: pid, source: nil, surfaceID: surfaceID, at: Date()),
        tabID: wrappedTabID
      )
      self?.markInitialAgentEventObserved(tabID: tabID)
      guard let state = self?.states[decoded] else {
        terminalLogger.debug("Dropped busy update for unknown worktree \(decoded)")
        return
      }
      // Register / unregister the agent PID so the 30s sweep can clear
      // stale busy state if the agent crashes before a clean hook fires.
      // Per-PID keyed so an inner agent (codex spawned by pi) doesn't
      // overwrite the outer's registration. Pre-upgrade hooks send
      // pid=nil; don't disturb existing tracking.
      if let pid {
        if active {
          var registrations = self?.agentPIDByTab[tabID] ?? [:]
          registrations[pid] = AgentPIDRegistration(
            worktreeID: decoded,
            surfaceID: surfaceID,
            pid: pid
          )
          self?.agentPIDByTab[tabID] = registrations
        } else if var registrations = self?.agentPIDByTab[tabID] {
          registrations.removeValue(forKey: pid)
          if registrations.isEmpty {
            self?.agentPIDByTab.removeValue(forKey: tabID)
          } else {
            self?.agentPIDByTab[tabID] = registrations
          }
        }
      }
      // Any authoritative busy transition (resumed or finished)
      // supersedes local optimistic state and a prior "awaiting input"
      // signal for this tab.
      self?.clearOptimisticBusy(tabID: tabID)
      self?.clearAwaitingInput(tabID: tabID, reason: "busy-changed")
      if active {
        self?.clearDeferredWork(tabID: tabID)
      }
      state.setAgentBusy(
        surfaceID: surfaceID,
        tabID: wrappedTabID,
        pid: pid,
        active: active
      )
      // Supacool transcript: when the agent reports going idle, snapshot
      // the full surface (visible + scrollback) into the per-session
      // transcript file. The recorder dedupes against its last snapshot,
      // so this is safe to call on every idle hook.
      if !active {
        if let fullText = state.readScreenContents(tabID: wrappedTabID, scope: .surface),
          !fullText.isEmpty
        {
          TranscriptRecorder.shared.snapshotOutput(tabID: wrappedTabID, fullText: fullText)
        }
      }
    }
  }

  private func configureNotificationHandler(_ server: AgentHookSocketServer) {
    server.onNotification = { [weak self] worktreeID, tabID, surfaceID, notification in
      let decoded = worktreeID.removingPercentEncoding ?? worktreeID
      let awaiting = Self.isAwaitingInputSignal(notification)
      let wrappedTabID = TerminalTabID(rawValue: tabID)
      // Debug-level tail for live `make run-app` inspection — the
      // structured `.hookEvent` entry written to the session JSONL below
      // is the authoritative record for post-hoc analysis.
      terminalLogger.debug(
        "hook worktree=\(decoded) tab=\(tabID) agent=\(notification.agent) "
          + "event=\(notification.event) awaiting=\(awaiting) "
          + "title=\(notification.title ?? "<nil>") "
          + "session=\(notification.sessionID ?? "<nil>") "
          + "body=\(notification.body ?? "<nil>")"
      )
      TranscriptRecorder.shared.append(
        event: .hookEvent(
          agent: notification.agent,
          event: notification.event,
          title: notification.title,
          body: notification.body,
          sessionID: notification.sessionID,
          awaitingClassifierVerdict: awaiting,
          surfaceID: surfaceID,
          at: Date()
        ),
        tabID: wrappedTabID
      )
      self?.markInitialAgentEventObserved(tabID: tabID)
      guard let state = self?.states[decoded] else {
        terminalLogger.debug("Dropped hook notification for unknown worktree \(decoded)")
        return
      }
      let title = notification.title ?? notification.agent
      let body = notification.body ?? ""
      state.appendHookNotification(title: title, body: body, surfaceID: surfaceID)
      self?.captureAgentNativeSessionID(tabID: tabID, notification: notification)
      if awaiting {
        // Claude's generic 60s idle reminder while a deferred-work lease
        // is live is expected noise, not evidence the agent needs the
        // user: the agent's own Stop message just declared it stopped on
        // purpose (holding for CI, a background poller, a timed
        // re-check). Promoting it here is what used to drop mid-hold
        // sessions into Waiting on Me one minute into every hold (trace
        // BF99621E, 04:49). Keep the lease; its TTL still resurfaces the
        // card if the agent never wakes. Hard signals (permission /
        // approval prompts) never match the idle-reminder check and
        // promote as before.
        if Self.isIdleReminderNotification(notification),
          self?.isDeferredWorkActive(worktreeID: decoded, tabID: wrappedTabID) == true
        {
          terminalLogger.info(
            "Idle reminder suppressed by deferred-work lease for tab \(tabID)"
          )
          return
        }
        // An authoritative awaiting-input hook means the agent has
        // yielded its turn and is blocked on the user — it is, by
        // definition, not busy. Clear the busy latch (and any optimistic
        // busy) so the card leaves "In Progress" for the waiting bucket.
        // Without this, Claude's idle "waiting for input" notification —
        // which does not always follow a Stop/busy=false edge — leaves
        // the latch stuck on and the card pinned green forever. This is
        // the mirror of `onBusy` clearing awaiting in the other
        // direction; busy and awaiting are mutually exclusive. Self-
        // correcting on a classifier false positive: the agent's next
        // busy hook re-sets busy and clears awaiting within seconds.
        self?.clearOptimisticBusy(tabID: tabID)
        state.clearAgentBusy(tabID: wrappedTabID)
        self?.clearDeferredWork(tabID: tabID)
        self?.markAwaitingInputSignal(worktreeID: decoded, tabID: tabID, source: "hook")
      } else if let duration = self?.deferredWorkLeaseDuration(for: notification) {
        self?.markDeferredWork(worktreeID: decoded, tabID: tabID, duration: duration)
      } else if notification.event == "Stop" {
        // A Stop hook is the agent's authoritative end-of-turn edge: it
        // forwarded its final message and yielded back to the user, so it
        // is — by definition — no longer busy. Clear the busy latch (and
        // any optimistic busy) here instead of relying on the *separate*
        // busy=0 progress hook firing on the same Stop event. When that
        // second hook races, is dropped, or (post supacode→supacool rename)
        // carries a stale `SUPACODE_*` env guard that never passes, the
        // latch stays stuck on and the card is pinned to "Working" forever.
        // Observed in a codex trace: 83 busy=1 edges plus a Stop
        // notification, but no busy=0. This mirrors the `awaiting` branch
        // above and `onBusy`'s busy=false path. Self-correcting: if the
        // agent resumes, its next busy=1 hook re-sets busy within seconds.
        self?.clearDeferredWork(tabID: tabID)
        self?.clearOptimisticBusy(tabID: tabID)
        state.clearAgentBusy(tabID: wrappedTabID)
      }
    }
  }

  /// Decide whether a hook event represents the agent actually blocking
  /// on user input (permission prompt, idle reminder) versus an
  /// informational ping that doesn't pause work.
  ///
  /// Claude Code fires `Notification` hooks for both blocking and
  /// informational cases. Historically we matched a small set of exact
  /// prefixes; Claude release-to-release wording drift was causing stuck
  /// "busy" cards (PreToolUse marked busy ON, but the follow-up
  /// Notification's body had shifted enough that the prefix list missed,
  /// so we never promoted the card to `.awaitingInput`).
  ///
  /// New rule: gate on `event == "Notification"` (the hook is already
  /// only fired in attention-requesting cases), then do a lossier
  /// case-insensitive contains-match on common indicator words. False-
  /// positive cost is bounded — the card flips to "Wants Input" until
  /// the next busy hook resets it (or the user clears via manual
  /// override). False-negative cost is much higher: stuck cards the
  /// user walks away from.
  ///
  /// Codex fires a dedicated `PermissionRequest` event for the blocking
  /// case, which is the clean signal we want.
  nonisolated static func isAwaitingInputSignal(_ notification: AgentHookNotification) -> Bool {
    let agent = notification.agent.lowercased()
    if agent.contains("claude") {
      guard notification.event == "Notification" else { return false }
      let body = (notification.body ?? "").lowercased()
      let indicators = ["permission", "waiting for", "input", "approval"]
      return indicators.contains(where: { body.contains($0) })
    }
    if agent.contains("codex") {
      // PermissionRequest is the precise signal; keep the legacy
      // wildcard on Notification for forward compatibility in case
      // Codex grows one.
      return notification.event == "PermissionRequest"
        || notification.event == "Notification"
    }
    // Unknown agents: preserve the legacy "any Notification event" heuristic.
    return notification.event == "Notification"
  }

  /// Claude's built-in idle reminder — fires ~60s after the prompt goes
  /// idle, with this exact body. It is the one awaiting-input signal that
  /// is *soft*: when the agent's most recent Stop declared deferred work
  /// (holding for CI, a background poller, a timed re-check), the reminder
  /// is expected noise, not evidence the agent needs the user. Permission /
  /// approval notifications never match — they stay authoritative.
  ///
  /// Caveat: the synthetic PreToolUse notification for blocking tools
  /// (`AgentHookSettingsCommand.preToolUseCommand`) reuses the same body,
  /// so a real question asked as the *first* tool call after a
  /// deferred-work Stop is masked until the lease TTL expires. Acceptable:
  /// any other hook edge (busy-on, non-deferred Stop) clears the lease
  /// first, and the lease is capped at `deferredWorkFallbackTTL`.
  nonisolated static func isIdleReminderNotification(
    _ notification: AgentHookNotification
  ) -> Bool {
    guard notification.agent.lowercased().contains("claude"),
      notification.event == "Notification"
    else { return false }
    let body = (notification.body ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    return body == "claude is waiting for your input"
  }

  /// Claude can stop its foreground turn while intentionally waiting on
  /// a timed check (CI, deploy retry, external poll). That is not
  /// "waiting on the user", but it also should not drop the card into
  /// Waiting on Me. Treat those Stop messages as a short, transient
  /// in-progress lease.
  nonisolated static func deferredWorkLeaseDuration(
    for notification: AgentHookNotification
  ) -> Duration? {
    guard isDeferredWorkSignal(notification) else { return nil }
    return parsedDeferredWorkDuration(
      from: notification.body?.lowercased() ?? "",
      buffer: deferredWorkLeaseBufferDefault
    ) ?? deferredWorkFallbackTTLDefault
  }

  private func deferredWorkLeaseDuration(for notification: AgentHookNotification) -> Duration? {
    guard Self.isDeferredWorkSignal(notification) else { return nil }
    return Self.parsedDeferredWorkDuration(
      from: notification.body?.lowercased() ?? "",
      buffer: deferredWorkLeaseBuffer
    ) ?? deferredWorkFallbackTTL
  }

  private nonisolated static func isDeferredWorkSignal(_ notification: AgentHookNotification) -> Bool {
    let agent = notification.agent.lowercased()
    guard agent.contains("claude"), notification.event == "Stop" else { return false }
    guard let body = notification.body?.lowercased(), !body.isEmpty else { return false }

    let deferredPhrases = [
      "check back",
      "next check",
      "re-checking",
      "standing by",
      "watching in background",
      "watching again",
      "will check",
      "will get pinged",
      "will iterate",
      "will report",
      "will report back",
      "will report when",
      "will stand by",
      "retry running",
      "iteration ",
      "scheduled a",
      "diagnostic is running",
      "diagnostic preview running",
      // Orchestration-loop holds (trace BF99621E): an evaluator ends its
      // turn while a doer's background poller watches CI. Phrases the
      // c-ci-triage evaluator actually emitted, generalized slightly.
      "waiting on ci",
      "waiting on live ci",
      "waiting for ci",
      "ci poll",
      "poll pending",
      "background poller",
      "background task",
      "holding for",
      "awaiting yield",
    ]

    return deferredPhrases.contains(where: { body.contains($0) })
  }

  private nonisolated static func parsedDeferredWorkDuration(from body: String, buffer: Duration) -> Duration? {
    let normalized = body.map { character -> Character in
      if character.isNumber || character.isLetter || character == "." {
        return character
      }
      return " "
    }
    let words = String(normalized).split(separator: " ").map(String.init)
    guard words.count >= 2 else { return nil }

    for index in words.indices.dropLast() {
      guard let value = Double(words[index]) else { continue }
      let unit = words[words.index(after: index)]
      let multiplier: Double
      if unit.hasPrefix("sec") {
        multiplier = 1
      } else if unit.hasPrefix("min") {
        multiplier = 60
      } else if unit.hasPrefix("hr") || unit.hasPrefix("hour") {
        multiplier = 60 * 60
      } else {
        continue
      }
      let seconds = Int((value * multiplier).rounded(.up))
      return .seconds(seconds) + buffer
    }
    return nil
  }

  /// Whether the rendered screen shows the agent asserting that it owns the
  /// turn — the interrupt hint (`esc to interrupt`) that claude and codex
  /// paint for the *entire* duration of a turn.
  ///
  /// This exists because the hook stream cannot answer "is it working?" on
  /// its own. `UserPromptSubmit` and `PreToolUse` are the only busy-on edges
  /// (see docs/agent-guides/hook-protocol.md), so a turn spent thinking with
  /// no tool call emits **nothing** — for minutes. In trace D5AF6FE4 a
  /// blocking-tool Notification cleared the busy latch, the awaiting lease
  /// expired 8s later, and the card sat in Waiting for 2.5 minutes while the
  /// screen plainly read "thinking more". The agent's own footer was the one
  /// signal that never lied.
  ///
  /// Deliberately *not* a generic "did the screen change" diff: a repaint
  /// also fires for cursor blinks, scrollback movement and window focus, none
  /// of which mean the agent is working — and a user scrolling an idle card
  /// would flip it green. The interrupt hint is the agent stating it owns the
  /// turn, which is precisely the question being asked.
  ///
  /// False-positive cost is bounded and self-correcting: an agent that merely
  /// *prints* the phrase holds the card green until the hint leaves the
  /// 12-line tail, and `relaxScreenWorking` drops the lease a few ticks later.
  /// Note the hint list is *interrupt*, never *cancel*: Claude's approval
  /// prompt footers read "Esc to cancel", so matching cancel would classify
  /// a permission prompt — the exact opposite state — as working.
  nonisolated static func isAgentWorkingScreen(_ screen: String) -> Bool {
    let normalized = screen.lowercased()
    let interruptHints = [
      "esc to interrupt",
      "ctrl+c to interrupt",
      "ctrl-c to interrupt",
    ]
    return interruptHints.contains(where: { normalized.contains($0) })
  }

  /// Screen-based fallback for hook misses *and* discriminator for the
  /// activity-resumed heuristic. Matches the inline approval UI used by
  /// Claude's edit / permission prompts and Codex's `Would you like to
  /// run the following command?` prompts. The screen-fallback path
  /// requires repeated identical samples before the tab is promoted;
  /// the activity-resumed path uses this to tell "prompt just finished
  /// rendering after the hook fired" apart from "user moved on".
  nonisolated static func isAwaitingInputPromptScreen(_ screen: String) -> Bool {
    let lines = screen
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map {
        $0
          .trimmingCharacters(in: .whitespacesAndNewlines)
          .lowercased()
      }
      .filter { !$0.isEmpty }

    guard !lines.isEmpty else { return false }

    let normalized = lines.joined(separator: "\n")
    // Lead phrases for known Claude/Codex prompts. The structural gates
    // below (approval options + dismiss option + footer) keep this list
    // safe from over-matching unrelated terminal output.
    let promptLeadPhrases = [
      "do you want to make this edit",
      "claude needs your permission",
      "do you want to allow claude",
      "allow claude to edit its own settings",
      "claude requested permissions",
      "do you want to proceed",
      "would you like to run the following command",
      "do you want to allow this",
      "do you trust",
      "approve this command",
      "allow this command",
      "needs your approval",
    ]
    let hasPrimaryPromptLead = promptLeadPhrases.contains(where: { normalized.contains($0) })
    let hasApprovalOptions =
      lines.contains { $0 == "1. yes" || $0.hasPrefix("1. yes,") || $0.hasPrefix("1. allow") }
      && lines.contains {
        $0 == "2. yes"
          || $0.hasPrefix("2. yes,")
          || $0.hasPrefix("2. allow")
          || $0 == "2. no"
      }
    let hasDismissOption = lines.contains { $0 == "3. no" || $0.hasPrefix("3. no,") }
    let hasPromptFooter =
      normalized.contains("esc to cancel")
      && (normalized.contains("tab to amend") || normalized.contains("enter to confirm"))

    return hasPrimaryPromptLead && hasApprovalOptions && hasDismissOption && hasPromptFooter
  }

  /// Persists the agent-native session identifier from a hook payload onto
  /// the matching `AgentSession` (by tabID). Silently no-ops when no session
  /// exists for the tab yet, or when the payload carried no session id.
  ///
  /// Hook ids from a *different* agent than the session was registered with
  /// are dropped — without this guard, a user who exits claude and runs codex
  /// in the same tab would have codex's UUIDv7 silently overwrite claude's
  /// captured id, leaving Resume to issue `claude --resume <codex-uuid>` and
  /// fail. The session "is" what it was launched as; foreign hooks shouldn't
  /// mutate its identity.
  private func captureAgentNativeSessionID(
    tabID: UUID,
    notification: AgentHookNotification
  ) {
    guard let sessionID = notification.sessionID, !sessionID.isEmpty else { return }
    $agentSessions.withLock { sessions in
      guard let (sessionIndex, terminalIndex) =
        Self.indices(for: tabID, in: sessions) else { return }
      let storedAgentID = sessions[sessionIndex].terminals[terminalIndex].agent?.id.lowercased()
      let hookAgentID = notification.agent.lowercased()
      guard storedAgentID == hookAgentID else {
        terminalLogger.warning(
          "Ignoring \(hookAgentID) hook session id for tab \(tabID) — "
            + "session terminal is registered as \(storedAgentID ?? "shell")"
        )
        return
      }
      guard sessions[sessionIndex].terminals[terminalIndex].agentNativeSessionID != sessionID
      else { return }
      sessions[sessionIndex].updateTerminal(id: tabID) {
        $0.agentNativeSessionID = sessionID
        $0.lastActivityAt = Date()
      }
      terminalLogger.info(
        "Captured \(notification.agent) session id \(sessionID) for tab \(tabID)"
      )
    }
  }

  /// Locate the (session, terminal) index pair owning a given tab id.
  /// Supports both the primary agent tab (where `session.id == tabID`) and
  /// auxiliary terminals living in the session's composition.
  private static func indices(
    for tabID: UUID,
    in sessions: [AgentSession]
  ) -> (sessionIndex: Int, terminalIndex: Int)? {
    for (sessionIndex, session) in sessions.enumerated() {
      if let terminalIndex = session.terminals.firstIndex(where: { $0.id == tabID }) {
        return (sessionIndex, terminalIndex)
      }
    }
    return nil
  }

  /// Auto-unpark: any input reaching the PTY (keystroke, paste,
  /// programmatic `sendText`) clears the `parked` bit so the user
  /// re-engaging with the session moves it back into the live buckets.
  /// No-ops when the session isn't parked, so per-keystroke calls are
  /// effectively free after the first one.
  private func handleInputObserved(worktreeID: Worktree.ID, tabID: TerminalTabID, text: String) {
    unparkSessionIfNeeded(tabID: tabID)
    guard Self.isSubmittedInput(text) else { return }
    // A submitted prompt wakes a tab whose scan had backed off — the agent is
    // about to start a turn that may never emit a busy hook.
    noteAgentSignal(tabID: tabID.rawValue)
    markOptimisticBusy(worktreeID: worktreeID, tabID: tabID)
  }

  private nonisolated static func isSubmittedInput(_ text: String) -> Bool {
    text.contains("\r") || text.contains("\n")
  }

  private func unparkSessionIfNeeded(tabID: TerminalTabID) {
    var didUnpark = false
    let now = Date()
    $agentSessions.withLock { sessions in
      guard let (sessionIndex, _) =
        Self.indices(for: tabID.rawValue, in: sessions) else { return }
      guard sessions[sessionIndex].parked else { return }
      sessions[sessionIndex].parked = false
      sessions[sessionIndex].updateTerminal(id: tabID.rawValue) { $0.lastActivityAt = now }
      didUnpark = true
    }
    guard didUnpark else { return }
    TranscriptRecorder.shared.append(
      event: .sessionLifecycle(kind: "unparked", context: "input", at: now),
      tabID: tabID
    )
    terminalLogger.info("Auto-unparked session \(tabID.rawValue) on input")
  }

  /// Persists that the tab has received at least one agent hook event.
  /// This lets the board keep a new session in "Starting" until the CLI
  /// has actually loaded its hook config, instead of guessing from a
  /// fixed launch delay.
  private func markInitialAgentEventObserved(tabID: UUID) {
    // Every hook (busy or notification) funnels through here, which makes it
    // the one place that re-arms the working-screen scan for this tab.
    noteAgentSignal(tabID: tabID)
    $agentSessions.withLock { sessions in
      guard let (sessionIndex, terminalIndex) =
        Self.indices(for: tabID, in: sessions) else { return }
      guard !sessions[sessionIndex].terminals[terminalIndex].hasObservedInitialAgentEvent
      else { return }
      sessions[sessionIndex].updateTerminal(id: tabID) {
        $0.hasObservedInitialAgentEvent = true
        $0.lastActivityAt = Date()
      }
    }
    firstHookDeadmanTasks.removeValue(forKey: tabID)?.cancel()
  }

  // MARK: - Supacool Matrix Board queries

  /// Whether the Ghostty tab with the given ID is currently busy (agent
  /// active or long-running command in progress). Reads flow through the
  /// @Observable tracking so callers re-render when state changes.
  func isAgentBusy(worktreeID: Worktree.ID, tabID: TerminalTabID) -> Bool {
    if states[worktreeID]?.isTabBusy(tabID) == true { return true }
    // The agent's own interrupt hint. Third source, and the only one that
    // survives a turn spent thinking with no tool call — the hook stream is
    // silent there, sometimes for minutes. See `isAgentWorkingScreen`.
    if screenWorkingByTab[tabID.rawValue]?.worktreeID == worktreeID { return true }
    return optimisticBusyByTab[tabID.rawValue]?.worktreeID == worktreeID
  }

  /// The single live-activity value the board classifies against. Collapses
  /// the busy / awaiting / deferred latches into one answer so callers can't
  /// fuse them inconsistently — and so "the agent is working" has exactly one
  /// definition. Precedence mirrors the boolean order this replaced: a
  /// pending prompt outranks busy, which outranks a deferred lease.
  func agentActivity(worktreeID: Worktree.ID, tabID: TerminalTabID) -> AgentActivity {
    if isAwaitingInput(worktreeID: worktreeID, tabID: tabID) { return .wantsInput }
    if isAgentBusy(worktreeID: worktreeID, tabID: tabID) { return .working }
    if isDeferredWorkActive(worktreeID: worktreeID, tabID: tabID) { return .deferredWork }
    return .idle
  }

  /// Whether the agent in this tab is paused on user input (permission
  /// prompt, clarification). Set by a `Notification` hook event, held on a
  /// short lease, and cleared when terminal activity resumes or the lease
  /// expires. Hook signals are preferred, but a narrow screen-pattern
  /// fallback can also promote known approval prompts when a hook is missed.
  func isAwaitingInput(worktreeID: Worktree.ID, tabID: TerminalTabID) -> Bool {
    awaitingInputByTab[tabID.rawValue]?.presented == true
  }

  /// Whether the agent has intentionally paused its foreground turn while
  /// waiting on an external timed check (CI, deploy retry, poll loop).
  /// This keeps the board in the working bucket without treating the
  /// session as blocked on user input.
  func isDeferredWorkActive(worktreeID: Worktree.ID, tabID: TerminalTabID) -> Bool {
    deferredWorkByTab[tabID.rawValue]?.worktreeID == worktreeID
  }

  /// Whether the session's tab still exists in any terminal state — false
  /// means the session is "detached" (PTY gone, e.g. after a relaunch).
  /// Supacool-specific; distinct from the existing `hasTab(tabID:)` which
  /// checks the currently-selected worktree only.
  func sessionTabExists(worktreeID: Worktree.ID, tabID: TerminalTabID) -> Bool {
    states[worktreeID]?.containsTabTree(tabID) ?? false
  }

  /// Fire a Ghostty binding action against the focused surface in the
  /// given worktree's state. Used by the Supacool "Recent prompts"
  /// popover to pre-populate the ⌘F search overlay via
  /// `performBindingAction("search:<needle>")`.
  @discardableResult
  func performBindingAction(worktreeID: Worktree.ID, action: String) -> Bool {
    states[worktreeID]?.performBindingActionOnFocusedSurface(action) ?? false
  }

  func handleCommand(_ command: TerminalClient.Command) {
    if handleTabCommand(command) {
      return
    }
    if handleBindingActionCommand(command) {
      return
    }
    if handleSearchCommand(command) {
      return
    }
    handleManagementCommand(command)
  }

  // swiftlint:disable:next cyclomatic_complexity
  private func handleTabCommand(_ command: TerminalClient.Command) -> Bool {
    switch command {
    case .createTab(let worktree, let runSetupScriptIfNew, let id):
      Task { createTabAsync(in: worktree, runSetupScriptIfNew: runSetupScriptIfNew, tabID: id) }
    case .createTabWithInput(let worktree, let input, let runSetupScriptIfNew, let id):
      Task {
        createTabAsync(in: worktree, runSetupScriptIfNew: runSetupScriptIfNew, initialInput: input, tabID: id)
      }
    case .createRemoteTab(let worktree, let command, let id, let surfaceID):
      // Supacool: bypass setup-script / default-shell plumbing entirely
      // — the supplied command is the full ssh invocation.
      let state = state(for: worktree) { false }
      _ = state.createTab(tabID: id, command: command, surfaceID: surfaceID)
    case .restoreShellLayout(let worktree, let tabID):
      restoreShellLayout(in: worktree, tabID: tabID)
    case .ensureInitialTab(let worktree, let runSetupScriptIfNew, let focusing):
      let state = state(for: worktree) { runSetupScriptIfNew }
      state.ensureInitialTab(focusing: focusing)
    case .stopRunScript(let worktree):
      _ = state(for: worktree).stopRunScript()
    case .runBlockingScript(let worktree, let kind, let script):
      _ = state(for: worktree).runBlockingScript(kind: kind, script)
    case .closeFocusedTab(let worktree):
      _ = closeFocusedTab(in: worktree)
    case .closeFocusedSurface(let worktree):
      _ = closeFocusedSurface(in: worktree)
    case .selectTab(let worktree, let tabID):
      state(for: worktree).selectTab(tabID)
    case .focusSurface(let worktree, let tabID, let surfaceID, let input):
      let terminal = state(for: worktree)
      terminal.selectTab(tabID)
      guard terminal.focusSurface(id: surfaceID) else {
        terminalLogger.warning("focusSurface: surface \(surfaceID) not found in worktree \(worktree.id).")
        break
      }
      if let input, !input.isEmpty {
        terminal.focusAndInsertText(input + "\r")
      }
    case .splitSurface(let worktree, let tabID, let surfaceID, let direction, let input, let id):
      let terminal = state(for: worktree)
      terminal.selectTab(tabID)
      let ghosttyDirection: GhosttySplitAction.NewDirection = direction == .vertical ? .down : .right
      let splitSucceeded = terminal.performSplitAction(
        .newSplit(direction: ghosttyDirection), for: surfaceID, newSurfaceID: id)
      guard splitSucceeded else {
        terminalLogger.warning("splitSurface: failed for surface \(surfaceID) in worktree \(worktree.id).")
        break
      }
      guard let input, !input.isEmpty else { break }
      terminal.focusAndInsertText(input + "\r")
    case .destroyTab(let worktree, let tabID):
      let terminal = state(for: worktree)
      guard terminal.tabManager.tabs.contains(where: { $0.id == tabID }) else {
        terminalLogger.warning("destroyTab: tab \(tabID.rawValue) not found in worktree \(worktree.id).")
        break
      }
      terminal.closeTab(tabID)
    case .destroySurface(let worktree, let tabID, let surfaceID):
      let terminal = state(for: worktree)
      terminal.selectTab(tabID)
      if !terminal.closeSurface(id: surfaceID) {
        terminalLogger.warning("destroySurface: surface \(surfaceID) not found in worktree \(worktree.id).")
      }
    case .sendText(let worktreeID, let tabID, let text):
      states[worktreeID]?.sendText(to: tabID, text: text)
    case .sendPrompt(let worktreeID, let tabID, let text):
      states[worktreeID]?.sendPrompt(to: tabID, text: text)
    default:
      return false
    }
    return true
  }

  private func handleSearchCommand(_ command: TerminalClient.Command) -> Bool {
    switch command {
    case .startSearch(let worktree):
      state(for: worktree).performBindingActionOnFocusedSurface("start_search")
    case .searchSelection(let worktree):
      state(for: worktree).performBindingActionOnFocusedSurface("search_selection")
    case .navigateSearchNext(let worktree):
      state(for: worktree).navigateSearchOnFocusedSurface(.next)
    case .navigateSearchPrevious(let worktree):
      state(for: worktree).navigateSearchOnFocusedSurface(.previous)
    case .endSearch(let worktree):
      state(for: worktree).performBindingActionOnFocusedSurface("end_search")
    case .createTab, .createTabWithInput, .createRemoteTab, .restoreShellLayout, .ensureInitialTab,
      .stopRunScript, .runBlockingScript, .closeFocusedTab, .closeFocusedSurface, .performBindingAction,
      .selectTab, .focusSurface, .splitSurface, .destroyTab, .destroySurface, .prune,
      .releaseOwnedProcesses, .setNotificationsEnabled, .setSelectedWorktreeID,
      .refreshTabBarVisibility, .sendText, .sendPrompt:
      return false
    }
    return true
  }

  private func handleBindingActionCommand(_ command: TerminalClient.Command) -> Bool {
    switch command {
    case .performBindingAction(let worktree, let action):
      state(for: worktree).performBindingActionOnFocusedSurface(action)
    case .createTab, .createTabWithInput, .createRemoteTab, .restoreShellLayout, .ensureInitialTab,
      .stopRunScript, .runBlockingScript, .closeFocusedTab, .closeFocusedSurface, .startSearch,
      .searchSelection, .navigateSearchNext, .navigateSearchPrevious, .endSearch, .selectTab,
      .focusSurface, .splitSurface, .destroyTab, .destroySurface, .prune, .releaseOwnedProcesses,
      .setNotificationsEnabled, .setSelectedWorktreeID, .refreshTabBarVisibility, .sendText,
      .sendPrompt:
      return false
    }
    return true
  }

  private func handleManagementCommand(_ command: TerminalClient.Command) {
    switch command {
    case .prune(let ids):
      prune(keeping: ids)
    case .releaseOwnedProcesses(let worktreePath):
      releaseOwnedProcesses(forWorktreePath: worktreePath)
    case .setNotificationsEnabled(let enabled):
      setNotificationsEnabled(enabled)
    case .refreshTabBarVisibility:
      for state in states.values {
        state.refreshTabBarVisibility()
      }
    case .setSelectedWorktreeID(let id):
      guard id != selectedWorktreeID else { return }
      if let previousID = selectedWorktreeID, let previousState = states[previousID] {
        previousState.setAllSurfacesOccluded()
        saveLayoutSnapshot?(previousID, captureLayoutSnapshotWithSessionIDs(from: previousState))
      }
      selectedWorktreeID = id
      terminalLogger.info("Selected worktree \(id ?? "nil")")
    case .createTab, .createTabWithInput, .createRemoteTab, .restoreShellLayout, .ensureInitialTab,
      .stopRunScript, .runBlockingScript, .closeFocusedTab, .closeFocusedSurface, .performBindingAction,
      .startSearch, .searchSelection, .navigateSearchNext, .navigateSearchPrevious, .endSearch,
      .selectTab, .focusSurface, .splitSurface, .destroyTab, .destroySurface, .sendText,
      .sendPrompt:
      assertionFailure("Unhandled terminal command reached management handler: \(command)")
    }
  }

  func eventStream() -> AsyncStream<TerminalClient.Event> {
    eventContinuation?.finish()
    let (stream, continuation) = AsyncStream.makeStream(of: TerminalClient.Event.self)
    eventContinuation = continuation
    lastNotificationIndicatorCount = nil
    if !pendingEvents.isEmpty {
      let bufferedEvents = pendingEvents
      pendingEvents.removeAll()
      for event in bufferedEvents {
        if case .notificationIndicatorChanged = event {
          continue
        }
        continuation.yield(event)
      }
    }
    emitNotificationIndicatorCountIfNeeded()
    return stream
  }

  func state(
    for worktree: Worktree,
    runSetupScriptIfNew: () -> Bool = { false }
  ) -> WorktreeTerminalState {
    if let existing = states[worktree.id] {
      if runSetupScriptIfNew() {
        existing.enableSetupScriptIfNeeded()
      }
      // Reload snapshot if the state has no tabs (e.g., setting was just enabled).
      if existing.tabManager.tabs.isEmpty,
        existing.pendingLayoutSnapshot == nil,
        !existing.needsSetupScript()
      {
        existing.pendingLayoutSnapshot = loadLayoutSnapshot?(worktree.id)
      }
      return existing
    }
    let runSetupScript = runSetupScriptIfNew()
    let state = WorktreeTerminalState(
      runtime: runtime,
      worktree: worktree,
      runSetupScript: runSetupScript
    )
    state.socketPath = socketServer?.socketPath
    // Load saved layout snapshot for restoration (skip when a setup script is pending).
    if !runSetupScript {
      state.pendingLayoutSnapshot = loadLayoutSnapshot?(worktree.id)
    }
    state.setNotificationsEnabled(notificationsEnabled)
    state.isSelected = { [weak self] in
      self?.selectedWorktreeID == worktree.id
    }
    state.onNotificationReceived = { [weak self] title, body in
      self?.emit(.notificationReceived(worktreeID: worktree.id, title: title, body: body))
    }
    state.onNotificationIndicatorChanged = { [weak self] in
      self?.emitNotificationIndicatorCountIfNeeded()
    }
    state.onTabCreated = { [weak self] in
      self?.emit(.tabCreated(worktreeID: worktree.id))
    }
    state.onTabClosed = { [weak self] in
      self?.emit(.tabClosed(worktreeID: worktree.id))
    }
    state.onFocusChanged = { [weak self] surfaceID in
      self?.emit(.focusChanged(worktreeID: worktree.id, surfaceID: surfaceID))
    }
    state.onTaskStatusChanged = { [weak self] status in
      self?.emit(.taskStatusChanged(worktreeID: worktree.id, status: status))
    }
    state.onBlockingScriptCompleted = { [weak self] kind, exitCode, tabId in
      self?.emit(.blockingScriptCompleted(worktreeID: worktree.id, kind: kind, exitCode: exitCode, tabId: tabId))
    }
    state.onCommandPaletteToggle = { [weak self] in
      self?.emit(.commandPaletteToggleRequested(worktreeID: worktree.id))
    }
    state.onSetupScriptConsumed = { [weak self] in
      self?.emit(.setupScriptConsumed(worktreeID: worktree.id))
    }
    state.onInputObserved = { [weak self] tabID, text in
      self?.handleInputObserved(worktreeID: worktree.id, tabID: tabID, text: text)
    }
    states[worktree.id] = state
    terminalLogger.info("Created terminal state for worktree \(worktree.id)")
    return state
  }

  private func restoreShellLayout(in worktree: Worktree, tabID: TerminalTabID) {
    let state = state(for: worktree) { false }
    state.pendingLayoutSnapshot = nil

    if state.containsTabTree(tabID) {
      state.selectTab(tabID)
      return
    }

    if let tabSnapshot = loadSavedLayoutSnapshot?(worktree.id)?.restorableTabSnapshot(for: tabID) {
      _ = state.restoreTabLayout(tabSnapshot, focusing: true)
      terminalLogger.info("Restored shell layout for tab \(tabID.rawValue) in worktree \(worktree.id)")
      return
    }

    _ = state.createTab(focusing: true, tabID: tabID.rawValue)
    terminalLogger.info(
      "Opened fresh shell for tab \(tabID.rawValue) in worktree \(worktree.id); no saved layout found"
    )
  }

  private func createTabAsync(
    in worktree: Worktree,
    runSetupScriptIfNew: Bool,
    initialInput: String? = nil,
    tabID: UUID? = nil
  ) {
    let state = state(for: worktree) { runSetupScriptIfNew }
    let setupScript: String?
    if state.needsSetupScript(), !Self.isMainRepoWorktree(worktree) {
      @SharedReader(.repositorySettings(worktree.repositoryRootURL))
      var settings = RepositorySettings.default
      setupScript = settings.setupScript
    } else {
      // Bugfix @claude [-] 2026-04-24: Setup scripts are
      // worktree-scoped by contract — they assume cwd is a freshly-
      // created worktree directory. When the user opens a tab in
      // directory mode (NewTerminalFeature `.repoRoot`), the
      // synthesized Worktree has workingDirectory == repositoryRootURL
      // and the script would otherwise run inside the main repo. A
      // user with `dev worktree --init-only` configured here had
      // pnpm wipe the main repo's node_modules before any guard
      // existed. Refuse and log so the user knows why.
      if state.needsSetupScript(), Self.isMainRepoWorktree(worktree) {
        terminalLogger.warning(
          "Skipping setup script for tab in main repo cwd "
            + "\(worktree.workingDirectory.path(percentEncoded: false)): "
            + "setup scripts only run inside linked worktrees, not the repo root."
        )
      }
      setupScript = nil
    }
    guard let createdTabID = state.createTab(setupScript: setupScript, initialInput: initialInput, tabID: tabID) else {
      return
    }
    markSubmittedInitialInputIfNeeded(
      worktreeID: worktree.id,
      tabID: createdTabID,
      initialInput: initialInput,
    )
  }

  /// True when the worktree's working directory is actually the repo
  /// root (directory-mode session) rather than a linked worktree dir.
  /// `standardizedFileURL` on both sides handles trailing-slash and
  /// `/private/tmp` symlink differences.
  nonisolated private static func isMainRepoWorktree(_ worktree: Worktree) -> Bool {
    worktree.workingDirectory.standardizedFileURL
      == worktree.repositoryRootURL.standardizedFileURL
  }

  @discardableResult
  func closeFocusedTab(in worktree: Worktree) -> Bool {
    let state = state(for: worktree)
    return state.closeFocusedTab()
  }

  @discardableResult
  func closeFocusedSurface(in worktree: Worktree) -> Bool {
    let state = state(for: worktree)
    return state.closeFocusedSurface()
  }

  func prune(keeping worktreeIDs: Set<Worktree.ID>) {
    var removed: [(Worktree.ID, WorktreeTerminalState)] = []
    for (id, state) in states where !worktreeIDs.contains(id) {
      removed.append((id, state))
    }
    for (id, state) in removed {
      saveLayoutSnapshot?(id, captureLayoutSnapshotWithSessionIDs(from: state))
      state.closeAllSurfaces()
    }
    if !removed.isEmpty {
      terminalLogger.info("Pruned \(removed.count) terminal state(s)")
    }
    states = states.filter { worktreeIDs.contains($0.key) }
    emitNotificationIndicatorCountIfNeeded()
  }

  func tabExists(worktreeID: Worktree.ID, tabID: TerminalTabID) -> Bool {
    states[worktreeID]?.hasTab(tabID) ?? false
  }

  func surfaceExists(worktreeID: Worktree.ID, tabID: TerminalTabID, surfaceID: UUID) -> Bool {
    states[worktreeID]?.hasSurface(surfaceID, in: tabID) ?? false
  }

  func readScreenContents(worktreeID: Worktree.ID, tabID: TerminalTabID) -> String? {
    states[worktreeID]?.readScreenContents(tabID: tabID)
  }

  /// Foreground PID of a session's focused surface, or nil when the
  /// tab has no live surface (not yet spawned, or already exited).
  /// Used by Supacool's per-session memory attribution.
  func foregroundPID(worktreeID: Worktree.ID, tabID: TerminalTabID) -> Int32? {
    states[worktreeID]?.foregroundPID(tabID: tabID)
  }

  func stateIfExists(for worktreeID: Worktree.ID) -> WorktreeTerminalState? {
    states[worktreeID]
  }

  func taskStatus(for worktreeID: Worktree.ID) -> WorktreeTaskStatus? {
    states[worktreeID]?.taskStatus
  }

  func isBlockingScriptRunning(kind: BlockingScriptKind, for worktreeID: Worktree.ID) -> Bool {
    states[worktreeID]?.isBlockingScriptRunning(kind: kind) == true
  }

  func setNotificationsEnabled(_ enabled: Bool) {
    notificationsEnabled = enabled
    for state in states.values {
      state.setNotificationsEnabled(enabled)
    }
    emitNotificationIndicatorCountIfNeeded()
  }

  func hasUnseenNotifications(for worktreeID: Worktree.ID) -> Bool {
    states[worktreeID]?.hasUnseenNotification == true
  }

  func saveAllLayoutSnapshots() {
    guard let saveLayoutSnapshot else {
      assertionFailure("saveLayoutSnapshot closure not configured.")
      return
    }
    for (id, state) in states {
      saveLayoutSnapshot(id, captureLayoutSnapshotWithSessionIDs(from: state))
    }
  }

  /// Wraps `WorktreeTerminalState.captureLayoutSnapshot()` and stamps each
  /// `TabSnapshot.sessionID` from `@Shared(.agentSessions)`. The state
  /// itself doesn't know about sessions; the manager owns that mapping.
  /// Tabs whose UUID matches no session's terminals (worktree-mode tabs)
  /// keep `sessionID == nil`.
  private func captureLayoutSnapshotWithSessionIDs(
    from state: WorktreeTerminalState
  ) -> TerminalLayoutSnapshot? {
    guard let snapshot = state.captureLayoutSnapshot() else { return nil }
    let sessions = agentSessions
    let enrichedTabs = snapshot.tabs.map { tab -> TerminalLayoutSnapshot.TabSnapshot in
      guard let tabID = tab.id else { return tab }
      let sessionID = sessions.first(where: { session in
        session.terminals.contains(where: { $0.id == tabID })
      })?.id
      return tab.withSessionID(sessionID)
    }
    return TerminalLayoutSnapshot(tabs: enrichedTabs, selectedTabIndex: snapshot.selectedTabIndex)
  }

  /// Add a new shell terminal as an auxiliary of the given session. Mints
  /// a fresh tab id, registers it on the session's `terminals` array,
  /// spawns the Ghostty tab in `worktree`, and persists the new layout.
  /// Returns the new tab id, or nil if no such session exists or no
  /// snapshot store is configured.
  @discardableResult
  func addShellTerminal(
    toSession sessionID: AgentSession.ID,
    in worktree: Worktree
  ) -> TerminalTabID? {
    let newTabID = UUID()
    var didAttach = false
    $agentSessions.withLock { sessions in
      guard let idx = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
      let terminal = SessionTerminal(id: newTabID, role: .shell)
      sessions[idx].terminals.append(terminal)
      didAttach = true
    }
    guard didAttach else { return nil }
    createTabAsync(in: worktree, runSetupScriptIfNew: false, tabID: newTabID)
    if let state = states[worktree.id] {
      saveLayoutSnapshot?(worktree.id, captureLayoutSnapshotWithSessionIDs(from: state))
    }
    return TerminalTabID(rawValue: newTabID)
  }

  /// Remove an auxiliary shell terminal from the session and destroy its
  /// tab. Refuses to remove the primary terminal — that one is the session
  /// itself; users delete the session to remove it.
  func removeAuxiliaryTerminal(
    sessionID: AgentSession.ID,
    terminalID: UUID,
    in worktree: Worktree
  ) {
    $agentSessions.withLock { sessions in
      guard let idx = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
      guard sessions[idx].primaryTerminalID != terminalID else {
        terminalLogger.warning(
          "Refusing to remove primary terminal \(terminalID) from session \(sessionID)"
        )
        return
      }
      sessions[idx].terminals.removeAll { $0.id == terminalID }
    }
    if let state = states[worktree.id] {
      state.closeTab(TerminalTabID(rawValue: terminalID))
      saveLayoutSnapshot?(worktree.id, captureLayoutSnapshotWithSessionIDs(from: state))
    }
  }

  /// Drop a deleted session's tabs from the persisted layout snapshot for
  /// `worktreeID`, leaving any other sessions sharing the worktree
  /// untouched. Called from BoardFeature's `removeSessionFromState` after
  /// the session is moved to trash. Matching is by `TabSnapshot.sessionID`,
  /// which the capture path stamps in `captureLayoutSnapshotWithSessionIDs`.
  func pruneLayoutsForRemovedSession(
    sessionID: AgentSession.ID,
    worktreeID: Worktree.ID
  ) {
    guard let snapshot = loadSavedLayoutSnapshot?(worktreeID) else { return }
    let filtered = snapshot.tabs.filter { $0.sessionID != sessionID }
    guard filtered.count != snapshot.tabs.count else { return }
    if filtered.isEmpty {
      saveLayoutSnapshot?(worktreeID, nil)
      return
    }
    // Clamp selectedTabIndex so it still points at a real tab.
    let selectedIndex = min(max(0, snapshot.selectedTabIndex), filtered.count - 1)
    let updated = TerminalLayoutSnapshot(
      tabs: filtered,
      selectedTabIndex: selectedIndex
    )
    saveLayoutSnapshot?(worktreeID, updated)
  }

  func surfaceBackgroundOpacity() -> Double {
    runtime.backgroundOpacity()
  }

  func unfocusedSplitOverlay() -> (fill: Color?, opacity: Double) {
    (runtime.unfocusedSplitFill(), runtime.unfocusedSplitOverlayOpacity())
  }

  private func markAwaitingInputSignal(
    worktreeID: Worktree.ID,
    tabID: UUID,
    source: String
  ) {
    markAwaitingInputSignal(
      worktreeID: worktreeID,
      tabID: tabID,
      fingerprint: screenFingerprint(worktreeID: worktreeID, tabID: TerminalTabID(rawValue: tabID)),
      source: source
    )
  }

  private func markAwaitingInputSignal(
    worktreeID: Worktree.ID,
    tabID: UUID,
    fingerprint: String?,
    source: String
  ) {
    var tracker = awaitingInputByTab[tabID] ?? AwaitingInputTracker(worktreeID: worktreeID)
    let wasActive = tracker.rawActive
    tracker.rawActive = true
    tracker.lastScreenFingerprint = fingerprint
    awaitingInputByTab[tabID] = tracker
    // Edge-triggered: don't spam the trace on every 1s screen-scan tick
    // that merely re-confirms an already-active awaiting state.
    if !wasActive {
      TranscriptRecorder.shared.append(
        event: .awaitingInputChanged(
          active: true, source: source, surfaceID: nil, at: Date()
        ),
        tabID: TerminalTabID(rawValue: tabID)
      )
    }
    scheduleAwaitingInputExpiry(for: tabID)
    scheduleAwaitingInputActivityPolling(for: tabID)
    scheduleAwaitingInputPresentationReconciliation(for: tabID, desiredState: true)
  }

  private func clearAwaitingInput(tabID: UUID, reason: String) {
    awaitingInputExpiryTasks.removeValue(forKey: tabID)?.cancel()
    awaitingInputActivityTasks.removeValue(forKey: tabID)?.cancel()
    awaitingInputPromptCandidates.removeValue(forKey: tabID)

    guard var tracker = awaitingInputByTab[tabID] else { return }
    let wasActive = tracker.rawActive
    tracker.rawActive = false
    tracker.lastScreenFingerprint = nil

    // Edge-triggered: only emit on true → false transitions.
    if wasActive {
      TranscriptRecorder.shared.append(
        event: .awaitingInputChanged(
          active: false, source: reason, surfaceID: nil, at: Date()
        ),
        tabID: TerminalTabID(rawValue: tabID)
      )
    }

    if tracker.presented {
      awaitingInputByTab[tabID] = tracker
      scheduleAwaitingInputPresentationReconciliation(for: tabID, desiredState: false)
    } else {
      awaitingInputDebounceTasks.removeValue(forKey: tabID)?.cancel()
      awaitingInputByTab.removeValue(forKey: tabID)
    }
  }

  private func scheduleAwaitingInputExpiry(for tabID: UUID) {
    awaitingInputExpiryTasks.removeValue(forKey: tabID)?.cancel()
    let sleep = self.sleep
    let awaitingInputTTL = self.awaitingInputTTL
    awaitingInputExpiryTasks[tabID] = Task { [weak self, sleep, awaitingInputTTL] in
      do {
        try await sleep(awaitingInputTTL)
      } catch {
        return
      }
      guard let self else { return }
      self.expireAwaitingInput(tabID: tabID)
    }
  }

  private func expireAwaitingInput(tabID: UUID) {
    awaitingInputExpiryTasks[tabID] = nil
    clearAwaitingInput(tabID: tabID, reason: "ttl-expired")
  }

  private func markDeferredWork(
    worktreeID: Worktree.ID,
    tabID: UUID,
    duration: Duration
  ) {
    deferredWorkByTab[tabID] = DeferredWorkTracker(worktreeID: worktreeID)
    deferredWorkExpiryTasks.removeValue(forKey: tabID)?.cancel()
    let sleep = self.sleep
    deferredWorkExpiryTasks[tabID] = Task { [weak self, sleep, duration] in
      do {
        try await sleep(duration)
      } catch {
        return
      }
      guard let self else { return }
      self.expireDeferredWork(tabID: tabID)
    }
  }

  private func clearDeferredWork(tabID: UUID) {
    deferredWorkExpiryTasks.removeValue(forKey: tabID)?.cancel()
    deferredWorkByTab.removeValue(forKey: tabID)
  }

  private func expireDeferredWork(tabID: UUID) {
    deferredWorkExpiryTasks[tabID] = nil
    deferredWorkByTab.removeValue(forKey: tabID)
  }

  private func markSubmittedInitialInputIfNeeded(
    worktreeID: Worktree.ID,
    tabID: TerminalTabID,
    initialInput: String?
  ) {
    guard let initialInput, Self.isSubmittedInput(initialInput) else { return }
    markOptimisticBusy(worktreeID: worktreeID, tabID: tabID)
    scheduleFirstHookDeadman(worktreeID: worktreeID, tabID: tabID)
  }

  #if DEBUG
    func markSubmittedInitialInputForTesting(
      worktreeID: Worktree.ID,
      tabID: TerminalTabID,
      initialInput: String?
    ) {
      markSubmittedInitialInputIfNeeded(
        worktreeID: worktreeID,
        tabID: tabID,
        initialInput: initialInput,
      )
    }

    func scheduleFirstHookDeadmanForTesting(
      worktreeID: Worktree.ID,
      tabID: TerminalTabID
    ) {
      scheduleFirstHookDeadman(worktreeID: worktreeID, tabID: tabID)
    }
  #endif

  private func scheduleFirstHookDeadman(worktreeID: Worktree.ID, tabID: TerminalTabID) {
    let rawTabID = tabID.rawValue
    // Shell sessions never produce hooks; scheduling for them would
    // guarantee a fired deadman + snapshot for every plain terminal.
    guard let session = agentSessions.first(where: { $0.id == rawTabID }),
      session.agent != nil
    else { return }
    // Resume / rerun paths land on a session that already saw hooks in
    // a previous run — skip rather than schedule a no-op.
    if let terminal = session.terminals.first(where: { $0.id == rawTabID }),
      terminal.hasObservedInitialAgentEvent
    {
      return
    }

    firstHookDeadmanTasks.removeValue(forKey: rawTabID)?.cancel()

    let sleep = self.sleep
    let delay = self.firstHookDeadmanDelay
    firstHookDeadmanTasks[rawTabID] = Task { [weak self, sleep, delay] in
      do {
        try await sleep(delay)
      } catch {
        return
      }
      guard let self else { return }
      self.fireFirstHookDeadman(worktreeID: worktreeID, tabID: tabID)
    }
  }

  private func fireFirstHookDeadman(worktreeID: Worktree.ID, tabID: TerminalTabID) {
    firstHookDeadmanTasks[tabID.rawValue] = nil
    // Tab torn down before the deadman fired — nothing to snapshot.
    guard states[worktreeID]?.containsTabTree(tabID) == true else { return }
    // Last-second race: a hook may have landed between the sleep
    // resuming and this method running. `cancel()` from
    // `markInitialAgentEventObserved` is best-effort, not synchronous.
    if let session = agentSessions.first(where: { $0.id == tabID.rawValue }),
      let terminal = session.terminals.first(where: { $0.id == tabID.rawValue }),
      terminal.hasObservedInitialAgentEvent
    {
      return
    }
    let fullText = readScreenContentsOverride?(worktreeID, tabID)
      ?? states[worktreeID]?.readScreenContents(tabID: tabID, scope: .surface)
    if let fullText, !fullText.isEmpty {
      TranscriptRecorder.shared.snapshotOutput(tabID: tabID, fullText: fullText)
    }
    TranscriptRecorder.shared.append(
      event: .sessionLifecycle(
        kind: "firstHookDeadman",
        context: Self.firstHookDeadmanContext(for: firstHookDeadmanDelay),
        at: Date()
      ),
      tabID: tabID
    )
    #if DEBUG
      firstHookDeadmanFireCount += 1
    #endif
  }

  /// Compact human-readable description of the deadman delay, suitable
  /// for the synthetic lifecycle event's `context`. `Duration`'s default
  /// description (`Duration(seconds: 10, attoseconds: 0)`) is too noisy
  /// for a transcript line.
  nonisolated static func firstHookDeadmanContext(for delay: Duration) -> String {
    "no agent hook within \(delay.components.seconds)s"
  }

  private func markOptimisticBusy(worktreeID: Worktree.ID, tabID: TerminalTabID) {
    let rawTabID = tabID.rawValue
    guard states[worktreeID]?.containsTabTree(tabID) == true else { return }
    guard agentSessions.contains(where: { $0.id == rawTabID && $0.agent != nil }) else { return }

    optimisticBusyByTab[rawTabID] = OptimisticBusyTracker(worktreeID: worktreeID)
    optimisticBusyExpiryTasks.removeValue(forKey: rawTabID)?.cancel()
    clearAwaitingInput(tabID: rawTabID, reason: "activity-resumed")
    clearDeferredWork(tabID: rawTabID)

    let sleep = self.sleep
    let optimisticBusyTTL = self.optimisticBusyTTL
    optimisticBusyExpiryTasks[rawTabID] = Task { [weak self, sleep, optimisticBusyTTL] in
      do {
        try await sleep(optimisticBusyTTL)
      } catch {
        return
      }
      guard let self else { return }
      self.expireOptimisticBusy(tabID: rawTabID)
    }
  }

  private func clearOptimisticBusy(tabID: UUID) {
    optimisticBusyExpiryTasks.removeValue(forKey: tabID)?.cancel()
    optimisticBusyByTab.removeValue(forKey: tabID)
  }

  private func expireOptimisticBusy(tabID: UUID) {
    optimisticBusyExpiryTasks[tabID] = nil
    optimisticBusyByTab.removeValue(forKey: tabID)
  }

  // MARK: - Screen-working lease

  /// Any evidence that an agent is alive in this tab — a hook, a submitted
  /// prompt, or its own interrupt hint. Re-arms the working-screen scan,
  /// which backs off after `screenWorkingQuietTickLimit` quiet ticks so a
  /// board of long-idle cards costs no screen reads.
  private func noteAgentSignal(tabID: UUID) {
    screenWorkingQuietTicks[tabID] = 0
  }

  /// True once a tab has gone quiet long enough to drop out of the
  /// working-screen scan. `noteAgentSignal` is the only way back in.
  private func isScreenWorkingScanQuiet(tabID: UUID) -> Bool {
    (screenWorkingQuietTicks[tabID] ?? 0) >= screenWorkingQuietTickLimit
  }

  private func markScreenWorking(worktreeID: Worktree.ID, tabID: UUID) {
    noteAgentSignal(tabID: tabID)
    screenWorkingByTab[tabID] = ScreenWorkingTracker(worktreeID: worktreeID)
    // The agent is visibly working, so it is not blocked on the user: a
    // still-raised awaiting lease is stale (the prompt it belonged to has
    // been answered) and would otherwise pin the card in "Wants Input".
    clearAwaitingInput(tabID: tabID, reason: "working-screen")
  }

  /// The hint wasn't on screen this tick. Drop the lease only after
  /// `screenWorkingMissGrace` consecutive misses so a single mid-repaint
  /// frame can't strobe the card between Working and Waiting.
  private func relaxScreenWorking(tabID: UUID) {
    screenWorkingQuietTicks[tabID, default: 0] += 1
    guard var tracker = screenWorkingByTab[tabID] else { return }
    tracker.missedSamples += 1
    if tracker.missedSamples >= screenWorkingMissGrace {
      screenWorkingByTab.removeValue(forKey: tabID)
      return
    }
    screenWorkingByTab[tabID] = tracker
  }

  private func clearScreenWorking(tabID: UUID) {
    screenWorkingByTab.removeValue(forKey: tabID)
  }

  private func scheduleAwaitingInputActivityPolling(for tabID: UUID) {
    guard awaitingInputActivityTasks[tabID] == nil else { return }
    let sleep = self.sleep
    let awaitingInputActivityPollInterval = self.awaitingInputActivityPollInterval
    awaitingInputActivityTasks[tabID] = Task { [weak self, sleep, awaitingInputActivityPollInterval] in
      while !Task.isCancelled {
        do {
          try await sleep(awaitingInputActivityPollInterval)
        } catch {
          return
        }
        guard let self else { return }
        self.sampleAwaitingInputActivity(tabID: tabID)
      }
    }
  }

  private func sampleAwaitingInputActivity(tabID: UUID) {
    guard var tracker = awaitingInputByTab[tabID] else {
      awaitingInputActivityTasks.removeValue(forKey: tabID)?.cancel()
      return
    }
    guard tracker.rawActive else {
      awaitingInputActivityTasks.removeValue(forKey: tabID)?.cancel()
      return
    }

    let tab = TerminalTabID(rawValue: tabID)
    let newFingerprint = screenFingerprint(worktreeID: tracker.worktreeID, tabID: tab)

    if let previousFingerprint = tracker.lastScreenFingerprint,
      let newFingerprint,
      previousFingerprint != newFingerprint
    {
      // Hook events frequently arrive *before* the agent has finished
      // painting its prompt UI — codex's PermissionRequest in
      // particular fires while "Would you like to run …" is still
      // streaming to the surface. The first activity-poll then sees a
      // different fingerprint and, naively, treats the prompt
      // finishing its paint as the user resuming work — clearing the
      // chip 1–2s after the hook even though the user never responded.
      // If the divergent screen still looks like a known approval
      // prompt, re-baseline and stay awaiting; only clear when the
      // surface has visibly moved past the prompt.
      if Self.isAwaitingInputPromptScreen(newFingerprint) {
        tracker.lastScreenFingerprint = newFingerprint
        awaitingInputByTab[tabID] = tracker
        scheduleAwaitingInputExpiry(for: tabID)
        return
      }
      tracker.lastScreenFingerprint = newFingerprint
      awaitingInputByTab[tabID] = tracker
      clearAwaitingInput(tabID: tabID, reason: "activity-resumed")
      return
    }

    // Screen confirms we're still awaiting (unchanged fingerprint, or the
    // first readable sample after a nil one). Re-arm the TTL so it means
    // "8s without any screen confirmation we're still waiting" rather than
    // an absolute "8s since the hook fired". Without this, a hooked agent
    // (Claude / Codex) that fires a single "waiting for input" hook and then
    // goes genuinely quiet — blocked on the user or a background process —
    // has its latch killed by `ttl-expired` after 8s and the card silently
    // drops from "Waiting on Me" to idle, even though the prompt is still up.
    // The hookless screen-fallback path already keeps awaiting alive by
    // re-marking every second; hooked tabs are skipped there (`sampleAwaiting
    // InputPromptScreens`), so this poll is their only keep-alive. Gated on a
    // non-nil fingerprint: when the surface is unreadable we let the original
    // deadline ride, preserving the TTL as a backstop.
    if newFingerprint != nil {
      scheduleAwaitingInputExpiry(for: tabID)
    }
    tracker.lastScreenFingerprint = newFingerprint
    awaitingInputByTab[tabID] = tracker
  }

  private func scheduleAwaitingInputPresentationReconciliation(
    for tabID: UUID,
    desiredState: Bool
  ) {
    awaitingInputDebounceTasks.removeValue(forKey: tabID)?.cancel()
    let sleep = self.sleep
    let debounce =
      desiredState
      ? awaitingInputTransitionOnDebounce
      : awaitingInputTransitionOffDebounce
    awaitingInputDebounceTasks[tabID] = Task { [weak self, sleep, debounce] in
      do {
        try await sleep(debounce)
      } catch {
        return
      }
      guard let self else { return }
      self.commitAwaitingInputPresentation(for: tabID, desiredState: desiredState)
    }
  }

  private func startAwaitingInputPromptScreenScanning() {
    guard awaitingInputPromptScanTask == nil else { return }
    let sleep = self.sleep
    let awaitingInputActivityPollInterval = self.awaitingInputActivityPollInterval
    awaitingInputPromptScanTask = Task { [weak self, sleep, awaitingInputActivityPollInterval] in
      while !Task.isCancelled {
        do {
          try await sleep(awaitingInputActivityPollInterval)
        } catch {
          return
        }
        guard let self else { return }
        await self.sampleAwaitingInputPromptScreens()
      }
    }
  }

  // The poll runs on @MainActor (this class is @MainActor) so every tab's
  // readScreenContents call is serialized on the same thread that drives
  // the UI. With many surfaces accumulated, scanning them all in one
  // tick can saturate the main thread long enough to feel like a freeze.
  // Three mitigations keep the read set small:
  //   1. Skip tabs the hooks currently report *busy*. While that latch is on
  //      the hook stream is authoritative and a read tells us nothing new.
  //      (A latch that never turns off is the stuck-busy watchdog's job.)
  //   2. Back off tabs that have been quiet for `screenWorkingQuietTickLimit`
  //      ticks with neither a hook nor an interrupt hint — they are genuinely
  //      idle, and the next hook or submit re-arms them via `noteAgentSignal`.
  //   3. `await Task.yield()` between tabs that we DO scan, so queued
  //      main-thread work (input handling, layout, animation ticks)
  //      interleaves instead of waiting for the entire sweep.
  //
  // Note what is *not* a mitigation any more: hooked tabs used to be skipped
  // outright, on the theory that the hook stream told us everything. It does
  // not — a turn spent thinking emits no busy hook at all — so hooked agent
  // tabs are now scanned for the interrupt hint whenever they are not
  // hook-busy. The awaiting-*prompt* fallback below stays hookless-only.
  private func sampleAwaitingInputPromptScreens() async {
    await tickAgentPIDSweepIfNeeded()
    await tickOwnedProcessRefreshIfNeeded()
    var openTabIDs = Set<UUID>()

    // Tabs that have ever received a hook event. Their awaiting state comes
    // from the hook layer, so they are excluded from the prompt fallback.
    let hookedTabIDs: Set<UUID> = Set(
      agentSessions.compactMap { $0.hasObservedInitialAgentEvent ? $0.id : nil }
    )
    // Tabs running an actual agent. A plain shell has no interrupt hint to
    // find, and we must never promote arbitrary shell output to "Working".
    let agentTabIDs: Set<UUID> = Set(
      agentSessions.flatMap { session in
        session.terminals.compactMap { $0.agent == nil ? nil : $0.id }
      }
    )

    // Snapshot the tab list up-front so the iteration is stable across
    // yields — tabs added or removed mid-scan get picked up next tick.
    let snapshot: [(Worktree.ID, TerminalTabID)] = states.flatMap { worktreeID, state in
      state.tabManager.tabs.map { (worktreeID, $0.id) }
    }

    for (worktreeID, tabID) in snapshot {
      let rawTabID = tabID.rawValue
      openTabIDs.insert(rawTabID)

      // Hooks say it's busy: authoritative, and no read needed. Keep the tab
      // armed so the scan is live the moment that latch drops.
      if states[worktreeID]?.isTabBusy(tabID) == true {
        noteAgentSignal(tabID: rawTabID)
        clearScreenWorking(tabID: rawTabID)
        awaitingInputPromptCandidates.removeValue(forKey: rawTabID)
        continue
      }

      let scanForWorking = agentTabIDs.contains(rawTabID) && !isScreenWorkingScanQuiet(tabID: rawTabID)
      let scanForPrompt = !hookedTabIDs.contains(rawTabID)
      guard scanForWorking || scanForPrompt else {
        awaitingInputPromptCandidates.removeValue(forKey: rawTabID)
        continue
      }

      let fingerprint = screenFingerprint(worktreeID: worktreeID, tabID: tabID)

      if scanForWorking {
        if let fingerprint, Self.isAgentWorkingScreen(fingerprint) {
          markScreenWorking(worktreeID: worktreeID, tabID: rawTabID)
        } else {
          relaxScreenWorking(tabID: rawTabID)
        }
      }

      guard scanForPrompt,
        let fingerprint,
        Self.isAwaitingInputPromptScreen(fingerprint)
      else {
        awaitingInputPromptCandidates.removeValue(forKey: rawTabID)
        if snapshot.count > 1 {
          await Task.yield()
        }
        continue
      }

      var candidate: AwaitingInputPromptCandidate
      if var existing = awaitingInputPromptCandidates[rawTabID] {
        if existing.fingerprint == fingerprint {
          existing.stableSampleCount += 1
        } else {
          existing = AwaitingInputPromptCandidate(worktreeID: worktreeID, fingerprint: fingerprint)
        }
        candidate = existing
      } else {
        candidate = AwaitingInputPromptCandidate(worktreeID: worktreeID, fingerprint: fingerprint)
      }

      awaitingInputPromptCandidates[rawTabID] = candidate

      if candidate.stableSampleCount >= awaitingInputPromptStableSamples {
        markAwaitingInputSignal(
          worktreeID: candidate.worktreeID,
          tabID: rawTabID,
          fingerprint: fingerprint,
          source: "screen-fallback"
        )
      }

      if snapshot.count > 1 {
        await Task.yield()
      }
    }

    let trackedTabIDs = Set(awaitingInputByTab.keys)
      .union(deferredWorkByTab.keys)
      .union(agentPIDByTab.keys)
      .union(optimisticBusyByTab.keys)
      .union(screenWorkingByTab.keys)
      .union(screenWorkingQuietTicks.keys)
    cleanupAwaitingInputTracking(closedTabIDs: trackedTabIDs.subtracting(openTabIDs))
    awaitingInputPromptCandidates = awaitingInputPromptCandidates.filter { openTabIDs.contains($0.key) }
  }

  #if DEBUG
    func sampleAwaitingInputPromptScreensForTesting() async {
      await sampleAwaitingInputPromptScreens()
    }

    func sampleAwaitingInputActivityForTesting(tabID: TerminalTabID) {
      sampleAwaitingInputActivity(tabID: tabID.rawValue)
    }

    func commitAwaitingInputPresentationForTesting(tabID: TerminalTabID, desiredState: Bool) {
      commitAwaitingInputPresentation(for: tabID.rawValue, desiredState: desiredState)
    }
  #endif

  private func cleanupAwaitingInputTracking(closedTabIDs: Set<UUID>) {
    guard !closedTabIDs.isEmpty else { return }
    for tabID in closedTabIDs {
      awaitingInputExpiryTasks.removeValue(forKey: tabID)?.cancel()
      awaitingInputActivityTasks.removeValue(forKey: tabID)?.cancel()
      awaitingInputDebounceTasks.removeValue(forKey: tabID)?.cancel()
      deferredWorkExpiryTasks.removeValue(forKey: tabID)?.cancel()
      awaitingInputPromptCandidates.removeValue(forKey: tabID)
      optimisticBusyExpiryTasks.removeValue(forKey: tabID)?.cancel()
      optimisticBusyByTab.removeValue(forKey: tabID)
      screenWorkingByTab.removeValue(forKey: tabID)
      screenWorkingQuietTicks.removeValue(forKey: tabID)
      // Trace: if the tab is being cleaned up while raw-active, record
      // the implicit clear so the session file shows the true→false
      // edge with a meaningful reason rather than a phantom stuck-on.
      if let tracker = awaitingInputByTab[tabID], tracker.rawActive {
        TranscriptRecorder.shared.append(
          event: .awaitingInputChanged(
            active: false, source: "tab-closed", surfaceID: nil, at: Date()
          ),
          tabID: TerminalTabID(rawValue: tabID)
        )
      }
      awaitingInputByTab.removeValue(forKey: tabID)
      deferredWorkByTab.removeValue(forKey: tabID)
      agentPIDByTab.removeValue(forKey: tabID)
    }
  }

  // MARK: - Agent PID sweep (Supacool)

  /// Ticks the sweep counter from the 1s prompt-scan loop and runs a
  /// full `kill(pid, 0)` sweep every `agentPIDSweepInterval`. Piggy-
  /// backing on the existing timer avoids a second background Task
  /// whose mere presence was observed to destabilise TestClock-driven
  /// tests when Swift Testing runs multiple tests in parallel.
  private func tickAgentPIDSweepIfNeeded() async {
    awaitingInputPromptScanTickCount &+= 1
    let ticksPerSweep = max(
      1,
      Int(agentPIDSweepInterval / awaitingInputActivityPollInterval)
    )
    guard awaitingInputPromptScanTickCount % ticksPerSweep == 0 else { return }
    await sweepAgentPIDs()
  }

  /// Piggy-backs on the 1s prompt-scan loop and refreshes the owned-
  /// process tracker every `ownedProcessRefreshInterval`. Same rationale
  /// as the agent PID sweep above — a separate background Task was
  /// observed to destabilise TestClock-driven tests under parallel
  /// Swift Testing. No-op when `ownedProcessTracker` is nil (default in
  /// tests). Refresh is non-destructive; actual termination happens
  /// only via `releaseOwnedProcesses(forWorktreePath:)`.
  private func tickOwnedProcessRefreshIfNeeded() async {
    guard let ownedProcessTracker else { return }
    ownedProcessRefreshTickCount &+= 1
    let ticksPerRefresh = max(
      1,
      Int(ownedProcessRefreshInterval / awaitingInputActivityPollInterval)
    )
    guard ownedProcessRefreshTickCount % ticksPerRefresh == 0 else { return }
    // `refresh()` is async: its proc-table walk runs on a detached Task
    // so the syscall storm doesn't block the @MainActor poll. See
    // `WorktreeOwnedProcessTracker.refresh()`.
    await ownedProcessTracker.refresh()
  }

  /// SIGTERMs every process the tracker has attributed to the given
  /// worktree path. Called by the AppFeature / BoardFeature reducers
  /// when a worktree is archived, removed, or all its sessions are
  /// parked. No-op when the tracker isn't wired (tests) or the
  /// worktree has no tracked processes.
  @discardableResult
  func releaseOwnedProcesses(forWorktreePath worktreePath: String) -> [pid_t] {
    guard let ownedProcessTracker else { return [] }
    return ownedProcessTracker.release(worktreePath: worktreePath)
  }

  /// Walks registered agent PIDs and clears busy/awaiting state for any
  /// whose process has died. Safety net for SIGKILL/OOM where no hook
  /// fires to report the transition. Per-PID granularity: a dead inner
  /// agent (codex) is dropped without disturbing a still-live outer
  /// agent (pi) on the same tab.
  func sweepAgentPIDs() async {
    guard !agentPIDByTab.isEmpty else { return }
    // Snapshot the (tab, registration) pairs and batch the liveness
    // probes off the main thread. Each `isProcessAlive` is a `kill(pid,
    // 0)` syscall in production; with N registered agents the cost is
    // small individually but stacks linearly and runs on @MainActor.
    let candidates: [(tabID: UUID, registration: AgentPIDRegistration)] =
      agentPIDByTab.flatMap { tabID, registrations in
        registrations.values.map { (tabID, $0) }
      }
    let isProcessAlive = self.isProcessAlive
    let dead: [(tabID: UUID, registration: AgentPIDRegistration)] = await Task.detached(
      priority: .utility
    ) {
      candidates.filter { !isProcessAlive($0.registration.pid) }
    }.value
    for (tabID, registration) in dead {
      terminalLogger.info(
        "Agent PID \(registration.pid) gone; clearing busy state on tab \(tabID)"
      )
      if var registrations = agentPIDByTab[tabID] {
        registrations.removeValue(forKey: registration.pid)
        if registrations.isEmpty {
          agentPIDByTab.removeValue(forKey: tabID)
        } else {
          agentPIDByTab[tabID] = registrations
        }
      }
      // Awaiting / deferred state belongs to the tab as a whole — only
      // clear it once the last registered agent dies.
      if agentPIDByTab[tabID] == nil {
        clearOptimisticBusy(tabID: tabID)
        clearAwaitingInput(tabID: tabID, reason: "pid-gone")
        clearDeferredWork(tabID: tabID)
        // The process is gone, so whatever is still painted on the surface is
        // a corpse — including its interrupt hint. Drop the lease outright
        // rather than let a frozen footer hold the card in "Working".
        clearScreenWorking(tabID: tabID)
      }
      guard let state = states[registration.worktreeID] else { continue }
      // Trace the synthesized clear so the session JSONL shows the
      // true→false edge with a reason instead of going silent.
      TranscriptRecorder.shared.append(
        event: .hookBusy(
          active: false, pid: registration.pid, source: "pid-gone",
          surfaceID: registration.surfaceID, at: Date()
        ),
        tabID: TerminalTabID(rawValue: tabID)
      )
      state.setAgentBusy(
        surfaceID: registration.surfaceID,
        tabID: TerminalTabID(rawValue: tabID),
        pid: registration.pid,
        active: false
      )
    }

    // Second pass — the stuck-busy watchdog. Dead PIDs were removed above,
    // so what remains in `agentPIDByTab` is the still-alive set. Snapshot
    // the keys before iterating because `reconcileStuckBusy` mutates the
    // dict (resets counters, or removes a cleared registration).
    let aliveKeys: [(tabID: UUID, pid: Int32)] = agentPIDByTab.flatMap { tabID, registrations in
      registrations.keys.map { (tabID, $0) }
    }
    for (tabID, pid) in aliveKeys {
      reconcileStuckBusy(tabID: tabID, pid: pid)
    }
  }

  /// Re-validates one still-alive, still-busy-registered agent PID. When it
  /// has had no busy hook for `stuckBusyStaleSweepThreshold` consecutive
  /// sweeps *and* the tab's screen has been byte-stable across them, the
  /// agent has finished its turn but dropped its end-of-turn edge — clear
  /// the latch for its surface so the card leaves "Working". A still-working
  /// agent either keeps emitting output (the screen changes, resetting the
  /// counter) or fires another busy hook (which recreates the registration
  /// with `staleSweeps == 0`), so neither trips this. Self-correcting: a
  /// later busy hook re-latches within seconds.
  ///
  /// The screen-stability gate is load-bearing: it's what separates a stuck
  /// latch from a legitimately long, quiet tool run — a plain time/TTL check
  /// can't tell them apart, which is exactly why the busy latch has never
  /// carried one. The screen read only happens here (30s sweep cadence, and
  /// only for tabs with a registered busy PID), not in the 1s prompt scan,
  /// so it doesn't reintroduce the per-tick main-thread cost that scan
  /// avoids for hooked tabs.
  private func reconcileStuckBusy(tabID: UUID, pid: Int32) {
    guard var registrations = agentPIDByTab[tabID],
      var registration = registrations[pid]
    else { return }
    let wrappedTabID = TerminalTabID(rawValue: tabID)
    let fingerprint = screenFingerprint(worktreeID: registration.worktreeID, tabID: wrappedTabID)

    // No readable screen, or it changed since last sweep → either still
    // producing output or no idle evidence yet. Reset and re-seed.
    guard let fingerprint, fingerprint == registration.lastFingerprint else {
      registration.staleSweeps = 0
      registration.lastFingerprint = fingerprint
      registrations[pid] = registration
      agentPIDByTab[tabID] = registrations
      return
    }

    registration.staleSweeps += 1
    registrations[pid] = registration
    agentPIDByTab[tabID] = registrations
    guard registration.staleSweeps >= stuckBusyStaleSweepThreshold else { return }

    terminalLogger.info(
      "Stuck-busy watchdog: PID \(pid) alive but idle for \(registration.staleSweeps) "
        + "sweeps with a stable screen; clearing busy latch on tab \(tabID)"
    )
    registrations.removeValue(forKey: pid)
    // Awaiting / deferred state belongs to the tab as a whole — only clear
    // it once the last registered agent on the tab is gone, mirroring the
    // dead-PID path above.
    if registrations.isEmpty {
      agentPIDByTab.removeValue(forKey: tabID)
      clearOptimisticBusy(tabID: tabID)
      clearAwaitingInput(tabID: tabID, reason: "busy-stale")
      clearDeferredWork(tabID: tabID)
    } else {
      agentPIDByTab[tabID] = registrations
    }
    // Trace the synthesized clear so the session JSONL shows the true→false
    // edge with a reason instead of going silent (the symptom in DF73B24A).
    TranscriptRecorder.shared.append(
      event: .hookBusy(
        active: false, pid: pid, source: "busy-stale",
        surfaceID: registration.surfaceID, at: Date()
      ),
      tabID: wrappedTabID
    )
    states[registration.worktreeID]?.setAgentBusy(
      surfaceID: registration.surfaceID,
      tabID: wrappedTabID,
      pid: pid,
      active: false
    )
  }

  /// Whether an agent PID has been registered for this tab (pre-upgrade
  /// hook clients don't send a PID so this can be nil even for a live
  /// agent). Returns any one of the registered PIDs when multiple agents
  /// share the tab. Exposed for tests and for the Matrix Board's sweep
  /// debug UI.
  func registeredAgentPID(tabID: UUID) -> Int32? {
    agentPIDByTab[tabID]?.values.first?.pid
  }

  /// All currently registered agent PIDs on this tab. A surface running
  /// nested agents (pi spawning codex) reports more than one. Exposed
  /// for tests; production callers use the bool from `isAgentBusy`.
  func registeredAgentPIDs(tabID: UUID) -> Set<Int32> {
    guard let registrations = agentPIDByTab[tabID] else { return [] }
    return Set(registrations.keys)
  }

  private func commitAwaitingInputPresentation(for tabID: UUID, desiredState: Bool) {
    awaitingInputDebounceTasks[tabID] = nil
    guard var tracker = awaitingInputByTab[tabID] else { return }
    guard tracker.rawActive == desiredState else { return }

    if tracker.presented == desiredState {
      if !tracker.rawActive {
        awaitingInputByTab.removeValue(forKey: tabID)
      }
      return
    }

    tracker.presented = desiredState
    if tracker.rawActive || tracker.presented {
      awaitingInputByTab[tabID] = tracker
    } else {
      awaitingInputByTab.removeValue(forKey: tabID)
    }
  }

  private func screenFingerprint(worktreeID: Worktree.ID, tabID: TerminalTabID) -> String? {
    let contents = readScreenContentsOverride?(worktreeID, tabID)
      ?? states[worktreeID]?.readScreenContents(tabID: tabID)
    let screen = contents?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let screen, !screen.isEmpty else { return nil }

    let tail = screen
      .split(separator: "\n", omittingEmptySubsequences: false)
      .suffix(awaitingInputFingerprintLineCount)
      .joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return tail.isEmpty ? nil : tail
  }

  private func emit(_ event: TerminalClient.Event) {
    guard let eventContinuation else {
      pendingEvents.append(event)
      return
    }
    eventContinuation.yield(event)
  }

  private func emitNotificationIndicatorCountIfNeeded() {
    let count = states.values.reduce(0) { count, state in
      count + (state.hasUnseenNotification ? 1 : 0)
    }
    if count != lastNotificationIndicatorCount {
      lastNotificationIndicatorCount = count
      emit(.notificationIndicatorChanged(count: count))
    }
  }
}
