import Testing

@testable import Supacool

struct SessionTabShortcutTests {
  @Test func digitsPickTheirPositionAndNineIsAlwaysLast() {
    #expect(SessionTabShortcut.tabIndex(forDigit: 1, tabCount: 3) == 0)
    #expect(SessionTabShortcut.tabIndex(forDigit: 3, tabCount: 3) == 2)
    #expect(SessionTabShortcut.tabIndex(forDigit: 9, tabCount: 3) == 2)
    #expect(SessionTabShortcut.tabIndex(forDigit: 9, tabCount: 12) == 11)
    #expect(SessionTabShortcut.tabIndex(forDigit: 8, tabCount: 12) == 7)
  }

  @Test func missingTabsAndOutOfRangeDigitsSelectNothing() {
    #expect(SessionTabShortcut.tabIndex(forDigit: 4, tabCount: 3) == nil)
    #expect(SessionTabShortcut.tabIndex(forDigit: 1, tabCount: 0) == nil)
    #expect(SessionTabShortcut.tabIndex(forDigit: 9, tabCount: 0) == nil)
    #expect(SessionTabShortcut.tabIndex(forDigit: 0, tabCount: 3) == nil)
    #expect(SessionTabShortcut.tabIndex(forDigit: 10, tabCount: 12) == nil)
  }

  @Test func adjacentTabWrapsAtBothEnds() {
    #expect(SessionTabShortcut.adjacentTabIndex(from: 0, step: 1, tabCount: 3) == 1)
    #expect(SessionTabShortcut.adjacentTabIndex(from: 2, step: 1, tabCount: 3) == 0)
    #expect(SessionTabShortcut.adjacentTabIndex(from: 0, step: -1, tabCount: 3) == 2)
    #expect(SessionTabShortcut.adjacentTabIndex(from: 1, step: -1, tabCount: 3) == 0)
  }

  @Test func adjacentTabNeedsSomethingToCycleTo() {
    #expect(SessionTabShortcut.adjacentTabIndex(from: 0, step: 1, tabCount: 1) == nil)
    #expect(SessionTabShortcut.adjacentTabIndex(from: nil, step: 1, tabCount: 3) == nil)
    #expect(SessionTabShortcut.adjacentTabIndex(from: 5, step: 1, tabCount: 3) == nil)
  }

  @Test func tooltipDigitIsTheInverseOfSelection() {
    for tabCount in 1...12 {
      for index in 0..<tabCount {
        guard let digit = SessionTabShortcut.digit(forTabAt: index, tabCount: tabCount) else {
          // Only tabs 9…n-1 (0-based 8…n-2) are unreachable.
          #expect(index >= 8 && index < tabCount - 1)
          continue
        }
        #expect(SessionTabShortcut.tabIndex(forDigit: digit, tabCount: tabCount) == index)
      }
    }
  }
}
