import Foundation
import Testing

@testable import Supacool

struct TrayCardGroupTests {
  private func creating(_ name: String) -> TrayCard {
    TrayCard(kind: .sessionCreating(sessionID: UUID(), displayName: name))
  }

  private func deleting(_ name: String) -> TrayCard {
    TrayCard(kind: .worktreeDeleting(worktreeID: "/tmp/\(name)", displayName: name))
  }

  private func spawnFailed(_ name: String) -> TrayCard {
    TrayCard(kind: .sessionSpawnFailed(displayName: name, message: "boom", draftSnapshot: nil))
  }

  @Test func emptyInputProducesNoGroups() {
    #expect(TrayCardGroup.group([]).isEmpty)
  }

  @Test func singleCardStaysUncollapsed() {
    let card = creating("CEN-8840")
    let groups = TrayCardGroup.group([card])

    #expect(groups.count == 1)
    #expect(groups[0].isCollapsed == false)
    #expect(groups[0].id == card.id)
    #expect(groups[0].displayNames == ["CEN-8840"])
  }

  @Test func sameKindCardsFoldIntoOneGroup() {
    let cards = [creating("A"), creating("B"), creating("C")]
    let groups = TrayCardGroup.group(cards)

    #expect(groups.count == 1)
    #expect(groups[0].isCollapsed)
    #expect(groups[0].cards.count == 3)
    // Identity follows the lead card so the slot keeps its place as
    // members land and drop out.
    #expect(groups[0].id == cards[0].id)
    #expect(groups[0].displayNames == ["A", "B", "C"])
  }

  @Test func differentCollapsibleKindsDoNotMix() {
    let groups = TrayCardGroup.group([creating("A"), deleting("wt-1"), creating("B")])

    #expect(groups.count == 2)
    #expect(groups[0].displayNames == ["A", "B"])
    #expect(groups[1].displayNames == ["wt-1"])
    #expect(groups[1].isCollapsed == false)
  }

  @Test func errorCardsNeverFold() {
    let groups = TrayCardGroup.group([spawnFailed("A"), spawnFailed("B")])

    #expect(groups.count == 2)
    #expect(groups.allSatisfy { !$0.isCollapsed })
  }

  @Test func firstAppearanceOrderIsPreserved() {
    // An error card between two spinners must not jump position when the
    // spinners fold together.
    let error = spawnFailed("boom")
    let groups = TrayCardGroup.group([error, creating("A"), creating("B")])

    #expect(groups.count == 2)
    #expect(groups[0].id == error.id)
    #expect(groups[1].displayNames == ["A", "B"])
  }
}
