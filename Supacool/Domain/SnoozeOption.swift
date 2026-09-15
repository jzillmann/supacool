import Foundation

/// Presets for "park this card and bring it back later". A snoozed session is
/// parked (or put on Standby when its tab is alive) with `parkedUntil` set; the
/// board's wake ticker unparks it once that moment passes. Its priority
/// flag is left untouched.
nonisolated enum SnoozeOption: String, CaseIterable, Identifiable, Sendable {
  case laterToday
  case tomorrowMorning
  case nextWeek

  /// Hour of day that "morning" presets wake at.
  static let morningHour = 9
  static let laterTodayInterval: TimeInterval = 3 * 60 * 60

  var id: String { rawValue }

  var label: String {
    switch self {
    case .laterToday: "Later Today (3 hours)"
    case .tomorrowMorning: "Tomorrow Morning"
    case .nextWeek: "Next Week (Monday Morning)"
    }
  }

  var systemImage: String {
    switch self {
    case .laterToday: "clock"
    case .tomorrowMorning: "sunrise"
    case .nextWeek: "calendar"
    }
  }

  func wakeDate(from now: Date, calendar: Calendar = .current) -> Date {
    switch self {
    case .laterToday:
      return now.addingTimeInterval(Self.laterTodayInterval)
    case .tomorrowMorning:
      let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
      return Self.morning(of: startOfTomorrow, calendar: calendar)
    case .nextWeek:
      // Weekday 2 = Monday in the Gregorian numbering. Always strictly after
      // today, so snoozing on a Monday means the following Monday.
      let startOfToday = calendar.startOfDay(for: now)
      let nextMonday = calendar.nextDate(
        after: startOfToday,
        matching: DateComponents(weekday: 2),
        matchingPolicy: .nextTime
      ) ?? startOfToday.addingTimeInterval(7 * 24 * 60 * 60)
      return Self.morning(of: nextMonday, calendar: calendar)
    }
  }

  private static func morning(of day: Date, calendar: Calendar) -> Date {
    calendar.date(bySettingHour: morningHour, minute: 0, second: 0, of: day) ?? day
  }
}
