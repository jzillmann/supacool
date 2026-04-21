import Foundation
import Testing

@testable import Supacool

@MainActor
struct ProcessFootprintTests {
  @Test func parsePSOutputHandlesTypicalLines() {
    let raw = """
      2136  3000   44624 /Applications/Supacool.app/Contents/MacOS/Supacool
       5822 2136     320 /usr/bin/login -flp jz /bin/bash --noprofile --norc
       5824 5822     320 -/bin/zsh
       9973 5824   21728 claude --resume abc --dangerously-skip-permissions
      """
    let rows = parsePSOutput(raw)
    #expect(rows.count == 4)
    #expect(rows[0].pid == 2136)
    #expect(rows[0].ppid == 3000)
    #expect(rows[0].rssKB == 44624)
    #expect(rows[0].command.hasPrefix("/Applications/Supacool.app"))
    #expect(rows[3].command == "claude --resume abc --dangerously-skip-permissions")
  }

  @Test func parsePSOutputSkipsMalformedLines() {
    // Blank lines, missing fields, and non-numeric PIDs must not crash
    // the parser — a partial snapshot is far better than a lost one.
    let raw = """

      2136 3000 44624 /Applications/Supacool.app/Contents/MacOS/Supacool
      not a real line
      123 abc 456 oops
      9973 5824 21728 claude --resume abc
      """
    let rows = parsePSOutput(raw)
    #expect(rows.count == 2)
    #expect(rows[0].pid == 2136)
    #expect(rows[1].pid == 9973)
  }

  @Test func buildSnapshotAttributesSessionFootprints() {
    // Same tree as the next test but with two anchors — one at the
    // claude PID (expect: claude + its mcp child), one at the dangling
    // zsh PID (expect: zsh alone, no descendants).
    let rows: [RawProcess] = [
      RawProcess(pid: 2136, ppid: 1, rssKB: 44_000, command: "Supacool"),
      RawProcess(pid: 5822, ppid: 2136, rssKB: 320, command: "login"),
      RawProcess(pid: 5824, ppid: 5822, rssKB: 320, command: "zsh"),
      RawProcess(pid: 9973, ppid: 5824, rssKB: 21_000, command: "claude"),
      RawProcess(pid: 10153, ppid: 9973, rssKB: 5_000, command: "mcp server"),
      RawProcess(pid: 11808, ppid: 2136, rssKB: 320, command: "login"),
      RawProcess(pid: 11810, ppid: 11808, rssKB: 320, command: "zsh"),
    ]
    let claudeSessionID = UUID()
    let shellSessionID = UUID()
    let missingSessionID = UUID()
    let anchors = [
      SessionAnchor(sessionID: claudeSessionID, anchorPID: 9973),
      SessionAnchor(sessionID: shellSessionID, anchorPID: 11810),
      SessionAnchor(sessionID: missingSessionID, anchorPID: 99999),
    ]
    let snapshot = buildSnapshot(
      from: rows,
      rootPID: 2136,
      sessionAnchors: anchors,
      now: Date(timeIntervalSince1970: 0)
    )
    #expect(snapshot.sessionFootprints.count == 2)
    #expect(snapshot.sessionFootprints[missingSessionID] == nil)

    let claude = snapshot.sessionFootprints[claudeSessionID]
    #expect(claude?.anchorPID == 9973)
    #expect(claude?.processCount == 2)
    #expect(claude?.aggregatedBytes == (21_000 + 5_000) * 1024)
    #expect(claude?.heaviestLeaf?.pid == 9973)

    let shell = snapshot.sessionFootprints[shellSessionID]
    #expect(shell?.anchorPID == 11810)
    #expect(shell?.processCount == 1)
    #expect(shell?.aggregatedBytes == 320 * 1024)
  }

  @Test func buildSnapshotAggregatesSubtreeRSS() {
    // Tree:
    //   Supacool (2136, 44_000 KB)
    //   ├── login (5822, 320 KB)
    //   │   └── zsh (5824, 320 KB)
    //   │       └── claude (9973, 21_000 KB)
    //   │           └── mcp (10153, 5_000 KB)
    //   └── login (11808, 320 KB)
    //       └── zsh (11810, 320 KB)
    //
    // Expected:
    //   top subtree 5822 aggregates 320 + 320 + 21_000 + 5_000 = 26_640 KB
    //   top subtree 11808 aggregates 320 + 320 = 640 KB
    //   subtrees sorted by aggregate descending
    let rows: [RawProcess] = [
      RawProcess(pid: 2136, ppid: 1, rssKB: 44_000, command: "Supacool"),
      RawProcess(pid: 5822, ppid: 2136, rssKB: 320, command: "login"),
      RawProcess(pid: 5824, ppid: 5822, rssKB: 320, command: "zsh"),
      RawProcess(pid: 9973, ppid: 5824, rssKB: 21_000, command: "claude"),
      RawProcess(pid: 10153, ppid: 9973, rssKB: 5_000, command: "mcp server"),
      RawProcess(pid: 11808, ppid: 2136, rssKB: 320, command: "login"),
      RawProcess(pid: 11810, ppid: 11808, rssKB: 320, command: "zsh"),
    ]
    let snapshot = buildSnapshot(from: rows, rootPID: 2136, now: Date(timeIntervalSince1970: 0))
    #expect(snapshot.rootBytes == 44_000 * 1024)
    #expect(snapshot.descendantCount == 6)
    #expect(snapshot.subtrees.count == 2)
    #expect(snapshot.subtrees[0].id == 5822)
    #expect(snapshot.subtrees[0].aggregatedBytes == (320 + 320 + 21_000 + 5_000) * 1024)
    #expect(snapshot.subtrees[0].processCount == 4)
    #expect(snapshot.subtrees[0].heaviestLeaf?.pid == 9973)
    #expect(snapshot.subtrees[1].id == 11808)
    #expect(snapshot.subtrees[1].aggregatedBytes == (320 + 320) * 1024)
  }

  @Test func buildSnapshotWithNoDescendants() {
    let rows: [RawProcess] = [
      RawProcess(pid: 2136, ppid: 1, rssKB: 44_000, command: "Supacool"),
    ]
    let snapshot = buildSnapshot(from: rows, rootPID: 2136, now: Date(timeIntervalSince1970: 0))
    #expect(snapshot.rootBytes == 44_000 * 1024)
    #expect(snapshot.descendantCount == 0)
    #expect(snapshot.subtrees.isEmpty)
  }
}
