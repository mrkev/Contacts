import Foundation

/// A contact paired with their next birthday, for the "Upcoming Birthdays" list.
nonisolated struct UpcomingBirthday: Identifiable, Hashable, Sendable {
    var contact: ContactSummary
    var nextDate: Date
    var daysAway: Int
    /// Age they turn on `nextDate`, when the birth year is known.
    var turningAge: Int?
    var id: String { contact.id }

    static func upcoming(
        from contacts: [ContactSummary],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [UpcomingBirthday] {
        let today = calendar.startOfDay(for: now)
        return contacts.compactMap { contact -> UpcomingBirthday? in
            guard let birthday = contact.birthday,
                  let next = nextOccurrence(of: birthday, after: today, calendar: calendar)
            else { return nil }
            let days = calendar.dateComponents([.day], from: today, to: next).day ?? 0
            var age: Int?
            if let year = birthday.year, year != NSDateComponentUndefined {
                age = calendar.component(.year, from: next) - year
            }
            return UpcomingBirthday(contact: contact, nextDate: next, daysAway: days, turningAge: age)
        }
        .sorted { ($0.daysAway, $0.contact.sortName) < ($1.daysAway, $1.contact.sortName) }
    }

    /// The next date (today or later) matching the birthday's month and day.
    /// Feb 29 birthdays fall on Feb 28 in non-leap years.
    static func nextOccurrence(of birthday: DateComponents, after today: Date, calendar: Calendar) -> Date? {
        guard let month = birthday.month, let day = birthday.day,
              month != NSDateComponentUndefined, day != NSDateComponentUndefined else { return nil }
        let thisYear = calendar.component(.year, from: today)
        for year in thisYear...(thisYear + 1) {
            if let date = date(year: year, month: month, day: day, calendar: calendar), date >= today {
                return date
            }
        }
        return nil
    }

    private static func date(year: Int, month: Int, day: Int, calendar: Calendar) -> Date? {
        var components = DateComponents(year: year, month: month, day: day)
        if let date = calendar.date(from: components),
           calendar.component(.month, from: date) == month {
            return date
        }
        // Day doesn't exist this year (e.g. Feb 29): use the month's last day.
        components.day = nil
        guard let firstOfMonth = calendar.date(from: components),
              let range = calendar.range(of: .day, in: .month, for: firstOfMonth) else { return nil }
        components.day = range.upperBound - 1
        return calendar.date(from: components)
    }
}

nonisolated enum BirthdayFormatting {
    /// "March 4, 1990", or "March 4" when the year is unknown.
    static func string(for birthday: DateComponents) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let hasYear = birthday.year.map { $0 != NSDateComponentUndefined } ?? false
        var components = DateComponents(year: hasYear ? birthday.year : 2000, month: birthday.month, day: birthday.day)
        components.calendar = calendar
        guard let date = calendar.date(from: components) else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.setLocalizedDateFormatFromTemplate(hasYear ? "yMMMMd" : "MMMMd")
        return formatter.string(from: date)
    }

    static func relativeDescription(daysAway: Int) -> String {
        switch daysAway {
        case 0: String(localized: "Today")
        case 1: String(localized: "Tomorrow")
        default: String(localized: "In \(daysAway) days")
        }
    }
}
