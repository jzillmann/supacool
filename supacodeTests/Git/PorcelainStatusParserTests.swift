import Testing

@testable import Supacool

struct PorcelainStatusParserTests {
  @Test func parsesWorkingTreeHiddenPathWithoutDroppingLeadingDot() {
    let files = PorcelainStatusParser.parse(" M .pi/prompts/pr-review.md\0")

    #expect(files.count == 1)
    #expect(files.first?.path == ".pi/prompts/pr-review.md")
    #expect(files.first?.status == .modified)
  }
}
