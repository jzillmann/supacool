import Testing

@testable import Supacool

struct HorizontalSwipeDetectorTests {
  @Test func emitsLeftSwipeAfterDominantHorizontalThreshold() {
    var detector = HorizontalSwipeDetector(threshold: 60, dominanceRatio: 1.2)

    #expect(
      detector.ingest(
        deltaX: 20,
        deltaY: 2,
        isBeginning: true,
        isEnding: false,
        isMomentum: false
      ) == nil
    )
    #expect(
      detector.ingest(
        deltaX: 45,
        deltaY: 3,
        isBeginning: false,
        isEnding: false,
        isMomentum: false
      ) == .left
    )
    #expect(
      detector.ingest(
        deltaX: 40,
        deltaY: 0,
        isBeginning: false,
        isEnding: false,
        isMomentum: false
      ) == nil
    )
  }

  @Test func emitsRightSwipeForNegativeHorizontalDelta() {
    var detector = HorizontalSwipeDetector(threshold: 60, dominanceRatio: 1.2)

    #expect(
      detector.ingest(
        deltaX: -70,
        deltaY: 5,
        isBeginning: true,
        isEnding: false,
        isMomentum: false
      ) == .right
    )
  }

  @Test func ignoresMostlyVerticalScroll() {
    var detector = HorizontalSwipeDetector(threshold: 60, dominanceRatio: 1.2)

    #expect(
      detector.ingest(
        deltaX: 80,
        deltaY: 120,
        isBeginning: true,
        isEnding: false,
        isMomentum: false
      ) == nil
    )
    #expect(
      detector.ingest(
        deltaX: 0,
        deltaY: 0,
        isBeginning: false,
        isEnding: true,
        isMomentum: false
      ) == nil
    )
  }

  @Test func resetsAfterGestureEnds() {
    var detector = HorizontalSwipeDetector(threshold: 60, dominanceRatio: 1.2)

    #expect(
      detector.ingest(
        deltaX: 70,
        deltaY: 0,
        isBeginning: true,
        isEnding: false,
        isMomentum: false
      ) == .left
    )
    #expect(
      detector.ingest(
        deltaX: 0,
        deltaY: 0,
        isBeginning: false,
        isEnding: true,
        isMomentum: false
      ) == nil
    )
    #expect(
      detector.ingest(
        deltaX: -70,
        deltaY: 0,
        isBeginning: true,
        isEnding: false,
        isMomentum: false
      ) == .right
    )
  }

  @Test func ignoresVerticalOscillationWithinOneGesture() {
    // Reading: fingers stay down (single .began/.ended), scrolling down then
    // back up so net vertical cancels to ~zero right as a little horizontal
    // drift crosses the threshold. The pre-fix net-Y guard would have mistaken
    // this for a left page swipe and yanked the user back to the board; the
    // vertical-*travel* guard must keep it a plain scroll.
    var detector = HorizontalSwipeDetector(threshold: 60, dominanceRatio: 1.2)

    #expect(
      detector.ingest(
        deltaX: 30,
        deltaY: 200,
        isBeginning: true,
        isEnding: false,
        isMomentum: false
      ) == nil
    )
    // accumulatedX now 65 (> threshold) and net vertical is only 10 — the exact
    // moment the old net-Y code fired. Travel-based vertical (390) keeps it a scroll.
    #expect(
      detector.ingest(
        deltaX: 35,
        deltaY: -190,
        isBeginning: false,
        isEnding: false,
        isMomentum: false
      ) == nil
    )
    #expect(
      detector.ingest(
        deltaX: 30,
        deltaY: 195,
        isBeginning: false,
        isEnding: false,
        isMomentum: false
      ) == nil
    )
  }

  @Test func ignoresMomentumScroll() {
    var detector = HorizontalSwipeDetector(threshold: 60, dominanceRatio: 1.2)

    #expect(
      detector.ingest(
        deltaX: 120,
        deltaY: 0,
        isBeginning: true,
        isEnding: false,
        isMomentum: true
      ) == nil
    )
  }
}
