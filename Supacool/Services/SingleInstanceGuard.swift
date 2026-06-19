import AppKit
import Foundation

/// Refuses to start a second Supacool against the same `~/.supacool` data
/// directory. Two non-isolated instances race the shared `agent-sessions.json`
/// (and the other persistence files) and silently corrupt board state — open
/// sessions vanish on whichever instance saves last. This is the failure mode
/// behind the 2026-06-18 board wipe.
///
/// Isolated preview instances redirect `$HOME` (see `scripts/preview-isolated.sh`),
/// so their `SupacoolPaths.baseDirectory` — and therefore this lock file —
/// differs; they are never blocked.
///
/// The lock is an `flock(2)` advisory lock held for the whole process lifetime.
/// `flock` is released automatically when the process dies, so a crashed
/// instance never leaves a stale lock behind (the reason to prefer it over a
/// PID file).
@MainActor
enum SingleInstanceGuard {
  /// Held for the process lifetime once acquired; intentionally never closed.
  private static var lockDescriptor: Int32 = -1

  /// True when the process is an XCTest/Swift-Testing host. The test runner
  /// launches the app *as* the host process, so enforcing the guard there
  /// would quit the host (and hang the runner) whenever a real Supacool — or
  /// a previous test host — already holds the lock. App startup skips the
  /// guard in this case; the pure `acquire(for:)` below stays testable.
  static var isRunningInTests: Bool {
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
      || NSClassFromString("XCTestCase") != nil
  }

  /// Attempts to become the sole instance for `directory`. Returns `true` if
  /// this process now holds the lock — or if the lock file couldn't be created
  /// at all, in which case we deliberately fail *open* rather than block a
  /// legitimate launch over an I/O error. Returns `false` only when another
  /// live instance already holds the lock.
  @discardableResult
  static func acquire(for directory: URL = SupacoolPaths.baseDirectory) -> Bool {
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let lockURL = directory.appending(path: ".instance.lock", directoryHint: .notDirectory)
    let descriptor = open(lockURL.path(percentEncoded: false), O_CREAT | O_RDWR, 0o644)
    guard descriptor >= 0 else { return true }
    if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
      close(descriptor)
      return false
    }
    lockDescriptor = descriptor
    return true
  }

  /// Shows a blocking explanation and quits. Called when `acquire` reports
  /// another live instance — before any board state is loaded or saved, so
  /// nothing can be corrupted.
  static func presentAlreadyRunningAndExit() -> Never {
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = "Supacool is already running"
    alert.informativeText = """
      Another Supacool instance is already using \
      \(SupacoolPaths.baseDirectory.path(percentEncoded: false)).

      Running two instances against the same data directory corrupts your board — \
      open sessions disappear. To preview a branch alongside your main app, launch \
      it with scripts/preview-isolated.sh, which gives the preview its own isolated \
      data directory.
      """
    alert.addButton(withTitle: "Quit")
    alert.runModal()
    exit(0)
  }
}
