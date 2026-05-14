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
