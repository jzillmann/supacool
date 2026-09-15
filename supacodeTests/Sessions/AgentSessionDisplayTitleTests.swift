import Foundation
import Testing

@testable import Supacool

struct AgentSessionDisplayTitleTests {
  @Test func stripsLeadingTicketAndSeparator() {
    #expect(AgentSession.title("CEN-9156 · Capability templates", strippingTicketPrefix: "CEN-9156")
      == "Capability templates")
    #expect(AgentSession.title("cen-9156: Capability templates", strippingTicketPrefix: "CEN-9156")
      == "Capability templates")
    #expect(AgentSession.title("CEN-9156 — Capability templates", strippingTicketPrefix: "CEN-9156")
      == "Capability templates")
  }

  @Test func leavesOtherTitlesAlone() {
    // Different ticket, id mid-title, longer id sharing the prefix, id-only title.
    #expect(AgentSession.title("CEN-1 · Fix", strippingTicketPrefix: "CEN-9156") == "CEN-1 · Fix")
    #expect(AgentSession.title("Fix CEN-9156 now", strippingTicketPrefix: "CEN-9156") == "Fix CEN-9156 now")
    #expect(AgentSession.title("CEN-91560 · Fix", strippingTicketPrefix: "CEN-9156") == "CEN-91560 · Fix")
    #expect(AgentSession.title("CEN-9156", strippingTicketPrefix: "CEN-9156") == "CEN-9156")
    #expect(AgentSession.title("CEN-9156 · ", strippingTicketPrefix: "CEN-9156") == "CEN-9156 · ")
    #expect(AgentSession.title("CEN-9156 · Fix", strippingTicketPrefix: nil) == "CEN-9156 · Fix")
  }

  @Test func usesFirstTicketReference() {
    let session = AgentSession(
      repositoryID: "/tmp/repo",
      worktreeID: "/tmp/repo",
      agent: nil,
      initialPrompt: "",
      displayName: "CEN-2 · Second",
      references: [.ticket(id: "CEN-2"), .ticket(id: "CEN-3")]
    )
    #expect(session.titleBesideTicketChip == "Second")
  }
}
