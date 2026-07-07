import Foundation
import Testing

@testable import Supacool

@MainActor
@Suite struct SingleInstanceGuardTests {
  private func tempDir() -> URL {
    FileManager.default.temporaryDirectory
      .appending(path: "siguard-\(UUID().uuidString)", directoryHint: .isDirectory)
  }

  @Test func acquiresWhenAloneAndCreatesLockFile() {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    #expect(SingleInstanceGuard.acquire(for: dir) == true)
    let lock = dir.appending(path: ".instance.lock", directoryHint: .notDirectory)
    #expect(FileManager.default.fileExists(atPath: lock.path(percentEncoded: false)))
  }

  // The whole point of the guard: when another live process already holds the
  // flock on the data dir, acquire() must report the directory busy. Uses a
  // python3 child as the "other instance" so the lock genuinely crosses a
  // process boundary (an in-process flock has unreliable self-conflict
  // semantics). Skips cleanly if python3 isn't available.
  @Test func refusesWhenAnotherProcessHoldsTheLock() throws {
    let python = "/usr/bin/python3"
    try #require(FileManager.default.isExecutableFile(atPath: python), "needs /usr/bin/python3")

    let dir = tempDir()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let lockPath = dir.appending(path: ".instance.lock", directoryHint: .notDirectory)
      .path(percentEncoded: false)
    let readyPath = dir.appending(path: ".ready", directoryHint: .notDirectory)
      .path(percentEncoded: false)

    // Child: take the exclusive flock, signal readiness via a file, then hold.
    let child = Process()
    child.executableURL = URL(fileURLWithPath: python)
    child.arguments = [
      "-c",
      """
      import fcntl, os, sys, time
      fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR)
      fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
      open(sys.argv[2], "w").close()
      time.sleep(30)
      """,
      lockPath,
      readyPath,
    ]
    try child.run()
    defer { child.terminate() }

    // Wait (bounded, real time — this is a cross-process I/O test, not
    // reducer logic) for the child to confirm it holds the lock.
    var locked = false
    for _ in 0..<200 where !locked {
      if FileManager.default.fileExists(atPath: readyPath) { locked = true; break }
      usleep(25_000)  // 25ms
    }
    try #require(locked, "child never acquired the lock")

    #expect(SingleInstanceGuard.acquire(for: dir) == false)
  }
}
