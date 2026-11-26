import Foundation
import Testing

@testable import Supacool

/// Since ghostty 1.4.0 the core refuses to open terminal-output links on macOS, so
/// Supacool applies the same `UntrustedURL` policy Ghostty's own app uses.
@Suite("UntrustedURL")
struct UntrustedURLTests {
  @Test func webAndMailLinksOpenDirectly() {
    #expect(
      UntrustedURL("https://github.com/acme/rocket/pull/5").decision
        == .allow(URL(string: "https://github.com/acme/rocket/pull/5")!))
    #expect(UntrustedURL("mailto:a@b.c").decision == .allow(URL(string: "mailto:a@b.c")!))
  }

  @Test func customSchemesAskFirst() {
    #expect(UntrustedURL("linear://issue/CEN-1").decision == .confirm(URL(string: "linear://issue/CEN-1")!))
  }

  @Test func malformedAndDeceptiveTargetsAreBlocked() {
    #expect(UntrustedURL("https:relative").decision == .deny(.invalidWebURL))
    #expect(UntrustedURL("not a url").decision == .deny(.malformedURL))
    #expect(UntrustedURL("https://a.com/\u{202E}gpj.exe").decision == .deny(.unsafeCharacters))
  }

  @Test func executableLocalFilesAreBlocked() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "untrusted-url-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let script = dir.appending(path: "payload.command")
    try "echo hi".write(to: script, atomically: true, encoding: .utf8)
    let note = dir.appending(path: "notes.txt")
    try "hi".write(to: note, atomically: true, encoding: .utf8)

    #expect(UntrustedURL(script.absoluteString).decision == .deny(.unsafeFile))
    #expect(UntrustedURL(note.absoluteString).decision == .allow(note.resolvingSymlinksInPath()))
    #expect(UntrustedURL(dir.appending(path: "missing.txt").absoluteString).decision == .deny(.inaccessibleFile))
  }

  @Test func bareLinkMatchesBecomeFileURLs() {
    let target = GhosttySurfaceBridge.untrustedTarget(forMatched: "~/notes.txt", isOSC8: false)
    #expect(target == URL(filePath: NSString(string: "~/notes.txt").standardizingPath).absoluteString)
    #expect(target.hasPrefix("file://"))
  }

  @Test func urlsAndOSC8TargetsPassThroughUnchanged() {
    #expect(GhosttySurfaceBridge.untrustedTarget(forMatched: "https://x.io/a", isOSC8: false) == "https://x.io/a")
    // OSC 8 never gets the bare-path treatment: a scheme-less OSC 8 target is malformed.
    #expect(GhosttySurfaceBridge.untrustedTarget(forMatched: "/tmp/a", isOSC8: true) == "/tmp/a")
    // Unsafe characters stay visible to UntrustedURL instead of being percent-encoded away.
    let sneaky = "/tmp/a\u{202E}txt"
    #expect(GhosttySurfaceBridge.untrustedTarget(forMatched: sneaky, isOSC8: false) == sneaky)
  }
}
