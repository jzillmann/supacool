import Foundation
import Testing

@testable import Supacool

struct SessionReferenceScannerTests {
  // MARK: - scanText (plain regex pass)

  @Test func scanTextExtractsTicketID() {
    let refs = SessionReferenceScannerLive.scanText("Please review CEN-1234 today.")
    #expect(refs.count == 1)
    #expect(refs.first == .ticket(id: "CEN-1234"))
  }

  @Test func scanTextExtractsPullRequestURL() {
    let refs = SessionReferenceScannerLive.scanText(
      "I opened https://github.com/foo/bar/pull/42 for review."
    )
    #expect(refs.count == 1)
    #expect(
      refs.first
        == .pullRequest(owner: "foo", repo: "bar", number: 42, state: nil)
    )
  }

  @Test func scanTextExtractsMultipleRefs() {
    let text = """
      Check CEN-1234 and FOO-5 as well.
      See https://github.com/org/repo/pull/100
      """
    let refs = SessionReferenceScannerLive.scanText(text)
    #expect(refs.count == 3)
    #expect(refs.contains(.ticket(id: "CEN-1234")))
    #expect(refs.contains(.ticket(id: "FOO-5")))
    #expect(
      refs.contains(
        .pullRequest(owner: "org", repo: "repo", number: 100, state: nil)
      )
    )
  }

  @Test func scanTextDedupesRepeatedRefs() {
    let text = "CEN-1234 is blocked by CEN-1234. Also CEN-1234 is urgent."
    let refs = SessionReferenceScannerLive.scanText(text)
    #expect(refs.count == 1)
    #expect(refs.first == .ticket(id: "CEN-1234"))
  }

  @Test func scanTextIgnoresLowercaseLookalikes() {
    let refs = SessionReferenceScannerLive.scanText("cen-1234 is not a ticket, nor is c-1")
    #expect(refs.isEmpty)
  }

  @Test func scanTextRespectsTicketPrefixAllowlist() {
    UserDefaults.standard.set("CEN", forKey: "supacool.references.ticketPrefixes")
    defer {
      UserDefaults.standard.removeObject(forKey: "supacool.references.ticketPrefixes")
    }

    let refs = SessionReferenceScannerLive.scanText(
      "Both CEN-1 and FOO-2 are mentioned; only CEN should match."
    )
    #expect(refs.count == 1)
    #expect(refs.first == .ticket(id: "CEN-1"))
  }

  @Test func scanTextEmptyReturnsEmpty() {
    #expect(SessionReferenceScannerLive.scanText("").isEmpty)
  }

  // MARK: - scanJSONL (full pipeline)

  @Test func scanJSONLFromSimpleUserMessage() {
    let jsonl = """
      {"type":"user","message":{"role":"user","content":"Please review CEN-42"}}
      """
    let refs = SessionReferenceScannerLive.scanJSONL(jsonl)
    #expect(refs == [.ticket(id: "CEN-42")])
  }

  @Test func scanJSONLFromAssistantTextBlocks() {
    let jsonl = """
      {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I opened https://github.com/foo/bar/pull/7"}]}}
      """
    let refs = SessionReferenceScannerLive.scanJSONL(jsonl)
    #expect(
      refs == [.pullRequest(owner: "foo", repo: "bar", number: 7, state: nil)]
    )
  }

  @Test func scanJSONLRecursesIntoToolResults() {
    let jsonl = """
      {"type":"user","message":{"role":"user","content":[{"tool_use_id":"abc","type":"tool_result","content":[{"type":"text","text":"Output mentions CEN-99"}]}]}}
      """
    let refs = SessionReferenceScannerLive.scanJSONL(jsonl)
    #expect(refs == [.ticket(id: "CEN-99")])
  }

  @Test func scanJSONLSkipsNonMessageEntries() {
    let jsonl = """
      {"type":"permission-mode","permissionMode":"bypass"}
      {"type":"attachment","content":"CEN-999 ignored here"}
      {"type":"user","message":{"role":"user","content":"FOO-1 matters"}}
      """
    let refs = SessionReferenceScannerLive.scanJSONL(jsonl)
    #expect(refs == [.ticket(id: "FOO-1")])
  }

  @Test func scanJSONLHandlesMalformedLines() {
    let jsonl = """
      not-json
      {"type":"user","message":{"role":"user","content":"CEN-1 is the ticket"}}
      {also bad
      """
    let refs = SessionReferenceScannerLive.scanJSONL(jsonl)
    #expect(refs == [.ticket(id: "CEN-1")])
  }

  @Test func scanJSONLDedupesAcrossLines() {
    let jsonl = """
      {"type":"user","message":{"role":"user","content":"fix CEN-1"}}
      {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"CEN-1 is in progress"}]}}
      """
    let refs = SessionReferenceScannerLive.scanJSONL(jsonl)
    #expect(refs.count == 1)
    #expect(refs.first == .ticket(id: "CEN-1"))
  }

  // MARK: - Path hashing

  @Test func hashProjectPathReplacesSlashes() {
    #expect(
      SessionReferenceScannerLive.hashProjectPath("/Users/jz/Projects/foo")
        == "-Users-jz-Projects-foo"
    )
  }

  @Test func jsonlURLBuildsExpectedPath() {
    let url = SessionReferenceScannerLive.jsonlURL(
      cwdPath: "/Users/jz/Projects/foo",
      agentNativeSessionID: "abcd-1234"
    )
    #expect(url.lastPathComponent == "abcd-1234.jsonl")
    #expect(url.pathComponents.contains("-Users-jz-Projects-foo"))
    #expect(url.pathComponents.contains(".claude"))
    #expect(url.pathComponents.contains("projects"))
  }

  // MARK: - URL generation

  @Test func ticketURLWithOrgSlug() {
    let ref = SessionReference.ticket(id: "CEN-1234")
    #expect(
      ref.url(linearOrgSlug: "centrum-ai")
        == URL(string: "https://linear.app/centrum-ai/issue/CEN-1234")
    )
  }

  @Test func ticketURLWithoutOrgSlugIsNil() {
    let ref = SessionReference.ticket(id: "CEN-1234")
    #expect(ref.url(linearOrgSlug: "") == nil)
    #expect(ref.url(linearOrgSlug: "   ") == nil)
  }

  @Test func pullRequestURL() {
    let ref = SessionReference.pullRequest(
      owner: "foo", repo: "bar", number: 42, state: .open
    )
    #expect(
      ref.url(linearOrgSlug: "")
        == URL(string: "https://github.com/foo/bar/pull/42")
    )
  }

  // MARK: - Codec round-trip

  @Test func referenceRoundTripsThroughJSON() throws {
    let original: [SessionReference] = [
      .ticket(id: "CEN-1234"),
      .pullRequest(owner: "foo", repo: "bar", number: 42, state: .merged),
    ]
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode([SessionReference].self, from: data)
    #expect(decoded == original)
  }
}
