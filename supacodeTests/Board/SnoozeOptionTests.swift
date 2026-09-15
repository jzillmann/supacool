import Foundation
import Testing

@testable import Supacool

struct SnoozeOptionTests {
  private static var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
    return calendar
  }

  private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
  }

  @Test func laterTodayAddsThreeHours() {
    let now = Self.date(2026, 9, 15, 14, 30)
    #expect(SnoozeOption.laterToday.wakeDate(from: now, calendar: Self.calendar) == Self.date(2026, 9, 15, 17, 30))
  }

  @Test func tomorrowMorningIsNineOnTheNextDayEvenAfterMidnight() {
    let lateEvening = Self.date(2026, 9, 15, 23, 50)
    let earlyMorning = Self.date(2026, 9, 16, 0, 10)
    #expect(
      SnoozeOption.tomorrowMorning.wakeDate(from: lateEvening, calendar: Self.calendar)
        == Self.date(2026, 9, 16, 9)
    )
    #expect(
      SnoozeOption.tomorrowMorning.wakeDate(from: earlyMorning, calendar: Self.calendar)
        == Self.date(2026, 9, 17, 9)
    )
  }

  @Test func nextWeekIsTheFollowingMondayMorning() {
    // 2026-09-15 is a Tuesday; 2026-09-21 is the next Monday.
    let tuesday = Self.date(2026, 9, 15, 11)
    #expect(SnoozeOption.nextWeek.wakeDate(from: tuesday, calendar: Self.calendar) == Self.date(2026, 9, 21, 9))
    // On a Monday it skips to the Monday after, not later the same day.
    let monday = Self.date(2026, 9, 21, 7)
    #expect(SnoozeOption.nextWeek.wakeDate(from: monday, calendar: Self.calendar) == Self.date(2026, 9, 28, 9))
  }
}
