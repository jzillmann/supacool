import Testing

@testable import Supacool

struct ReferenceStackPopoverPresentationTests {
  @Test func mergedPullRequestsAtThresholdStayInline() {
    let references = (1...ReferenceStackPopoverPresentation.mergedPullRequestCollapseThreshold).map {
      pr($0, state: .merged)
    }

    let presentation = ReferenceStackPopoverPresentation(
      references: references,
      collapseMergedPullRequests: true
    )

    #expect(presentation.primaryReferences == references)
    #expect(presentation.collapsedMergedPullRequests.isEmpty)
  }

  @Test func mergedPullRequestsOverThresholdCollapseIntoOneGroup() {
    let firstMerged = pr(1, state: .merged)
    let open = pr(2, state: .open)
    let remainingMerged = (3...7).map { pr($0, state: .merged) }
    let unresolved = pr(8, state: nil)
    let references = [firstMerged, open] + remainingMerged + [unresolved]

    let presentation = ReferenceStackPopoverPresentation(
      references: references,
      collapseMergedPullRequests: true
    )

    #expect(presentation.primaryReferences == [open, unresolved])
    #expect(presentation.collapsedMergedPullRequests == [firstMerged] + remainingMerged)
  }

  @Test func mergedPullRequestCollapseCanBeDisabled() {
    let references = (1...(ReferenceStackPopoverPresentation.mergedPullRequestCollapseThreshold + 1)).map {
      pr($0, state: .merged)
    }

    let presentation = ReferenceStackPopoverPresentation(
      references: references,
      collapseMergedPullRequests: false
    )

    #expect(presentation.primaryReferences == references)
    #expect(presentation.collapsedMergedPullRequests.isEmpty)
  }
}

private func pr(_ number: Int, state: PRState?) -> SessionReference {
  .pullRequest(owner: "foo", repo: "bar", number: number, state: state)
}
