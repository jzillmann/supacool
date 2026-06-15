import Testing

@testable import Supacool

struct ReferenceStackPopoverPresentationTests {
  @Test func mergedPullRequestsBelowThresholdStayInline() {
    let references = (1..<ReferenceStackPopoverPresentation.pullRequestCollapseThreshold).map {
      pr($0, state: .merged)
    }

    let presentation = ReferenceStackPopoverPresentation(
      references: references,
      collapsePullRequests: true
    )

    #expect(presentation.primaryReferences == references)
    #expect(presentation.collapsedMergedPullRequests.isEmpty)
    #expect(presentation.collapsedClosedPullRequests.isEmpty)
  }

  @Test func mergedPullRequestsAtThresholdCollapseIntoOneGroup() {
    let firstMerged = pr(1, state: .merged)
    let open = pr(2, state: .open)
    let remainingMerged = (3...4).map { pr($0, state: .merged) }
    let unresolved = pr(8, state: nil)
    let references = [firstMerged, open] + remainingMerged + [unresolved]

    let presentation = ReferenceStackPopoverPresentation(
      references: references,
      collapsePullRequests: true
    )

    #expect(presentation.primaryReferences == [open, unresolved])
    #expect(presentation.collapsedMergedPullRequests == [firstMerged] + remainingMerged)
    #expect(presentation.collapsedClosedPullRequests.isEmpty)
  }

  @Test func closedPullRequestsAtThresholdCollapseIntoOwnGroup() {
    let open = pr(1, state: .open)
    let closed = (2...4).map { pr($0, state: .closed) }
    let references = [open] + closed

    let presentation = ReferenceStackPopoverPresentation(
      references: references,
      collapsePullRequests: true
    )

    #expect(presentation.primaryReferences == [open])
    #expect(presentation.collapsedClosedPullRequests == closed)
    #expect(presentation.collapsedMergedPullRequests.isEmpty)
  }

  @Test func mergedAndClosedCollapseIndependently() {
    let open = pr(1, state: .open)
    let merged = (2...4).map { pr($0, state: .merged) }
    // Only two closed PRs — below threshold, so they stay inline.
    let closed = (5...6).map { pr($0, state: .closed) }
    let references = [open] + merged + closed

    let presentation = ReferenceStackPopoverPresentation(
      references: references,
      collapsePullRequests: true
    )

    #expect(presentation.primaryReferences == [open] + closed)
    #expect(presentation.collapsedMergedPullRequests == merged)
    #expect(presentation.collapsedClosedPullRequests.isEmpty)
  }

  @Test func featuredPullRequestPrefersOpenOverOlderSettledOnes() {
    let references = [pr(1, state: .merged), pr(2, state: .merged), pr(3, state: .open)]

    #expect(
      ReferenceStackPopoverPresentation.featuredPullRequest(in: references) == pr(3, state: .open)
    )
  }

  @Test func featuredPullRequestFallsBackToDraft() {
    let references = [pr(1, state: .merged), pr(2, state: .draft), pr(3, state: .closed)]

    #expect(
      ReferenceStackPopoverPresentation.featuredPullRequest(in: references) == pr(2, state: .draft)
    )
  }

  @Test func featuredPullRequestFallsBackToNewestWhenAllSettled() {
    let references = [pr(1, state: .merged), pr(2, state: .closed), pr(3, state: nil)]

    #expect(
      ReferenceStackPopoverPresentation.featuredPullRequest(in: references) == pr(3, state: nil)
    )
  }

  @Test func pullRequestCollapseCanBeDisabled() {
    let references = (1...(ReferenceStackPopoverPresentation.pullRequestCollapseThreshold + 1)).map {
      pr($0, state: .merged)
    }

    let presentation = ReferenceStackPopoverPresentation(
      references: references,
      collapsePullRequests: false
    )

    #expect(presentation.primaryReferences == references)
    #expect(presentation.collapsedMergedPullRequests.isEmpty)
    #expect(presentation.collapsedClosedPullRequests.isEmpty)
  }
}

private func pr(_ number: Int, state: PRState?) -> SessionReference {
  .pullRequest(owner: "foo", repo: "bar", number: number, state: state, title: nil)
}
