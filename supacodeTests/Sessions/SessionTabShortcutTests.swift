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
