//
//  ContactsTests.swift
//  ContactsTests
//

import Contacts
import Foundation
import Testing
@testable import ContactsApp

private func summary(
    _ name: String, sortName: String? = nil, phones: [String] = [], emails: [String] = [],
    subtitle: String? = nil, birthday: DateComponents? = nil
) -> ContactSummary {
    ContactSummary(id: UUID().uuidString, displayName: name, sortName: sortName ?? name, subtitle: subtitle,
                   initials: String(name.prefix(1)), birthday: birthday, phoneNumbers: phones, emailAddresses: emails)
}

struct SearchTests {
    @Test func matchesNameIgnoringCaseAndDiacritics() {
        let contact = summary("José Álvarez")
        #expect(contact.matches("jose"))
        #expect(contact.matches("ALVAREZ jos"))
        #expect(!contact.matches("maria"))
    }

    @Test func matchesPhoneDigitsRegardlessOfFormatting() {
        let contact = summary("Kate Bell", phones: ["(555) 564-8583"])
        #expect(contact.matches("5648583"))
        #expect(contact.matches("564-8583"))
        #expect(!contact.matches("12"))      // too short to be a phone search
        #expect(!contact.matches("9999999"))
    }

    @Test func matchesEmailAndCompany() {
        let contact = summary("Anna Haro", emails: ["anna-haro@mac.com"], subtitle: "Creative Consulting")
        #expect(contact.matches("haro@mac"))
        #expect(contact.matches("creative"))
    }

    @Test func emptyQueryMatchesEverything() {
        #expect(summary("Anyone").matches("   "))
    }
}

struct SectionTests {
    @Test func groupsByFoldedInitialAndPutsSymbolsLast() {
        let sections = ContactSection.sections(for: [
            summary("1-800-Flowers"),
            summary("Émile", sortName: "Émile"),
            summary("Anna"),
            summary("eve"),
            summary("Bob"),
        ])
        #expect(sections.map(\.title) == ["A", "B", "E", "#"])
        #expect(sections.first { $0.title == "E" }?.contacts.map(\.displayName) == ["Émile", "eve"])
    }
}

struct BirthdayTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    @Test func ordersByNextOccurrenceAndComputesAge() {
        let now = date(2026, 11, 12)
        let upcoming = UpcomingBirthday.upcoming(from: [
            summary("Later", birthday: DateComponents(month: 1, day: 5)),
            summary("Today", birthday: DateComponents(year: 1990, month: 11, day: 12)),
            summary("Soon", birthday: DateComponents(month: 11, day: 20)),
            summary("None"),
        ], now: now, calendar: calendar)

        #expect(upcoming.map(\.contact.displayName) == ["Today", "Soon", "Later"])
        #expect(upcoming.map(\.daysAway) == [0, 8, 54])
        #expect(upcoming[0].turningAge == 36)
        #expect(upcoming[1].turningAge == nil)
    }

    @Test func leapDayFallsBackToFebruary28() {
        let next = UpcomingBirthday.nextOccurrence(of: DateComponents(month: 2, day: 29),
                                                   after: date(2026, 11, 12), calendar: calendar)
        #expect(next == date(2027, 2, 28))
    }

    @Test func birthdayDraftRoundTripsYearlessDates() {
        let draft = BirthdayDraft(components: DateComponents(month: 7, day: 4))
        #expect(draft?.includesYear == false)
        #expect(draft?.components.month == 7)
        #expect(draft?.components.day == 4)
        #expect(draft?.components.year == nil)
    }
}

struct ContactDraftTests {
    private func sampleContact() -> CNMutableContact {
        let contact = CNMutableContact()
        contact.givenName = "John"
        contact.familyName = "Appleseed"
        contact.organizationName = "Apple"
        contact.phoneNumbers = [
            CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: "888-555-5512")),
            CNLabeledValue(label: CNLabelHome, value: CNPhoneNumber(stringValue: "888-555-1212")),
        ]
        contact.emailAddresses = [CNLabeledValue(label: CNLabelWork, value: "john@example.com" as NSString)]
        let address = CNMutablePostalAddress()
        address.street = "3494 Kuhl Avenue"
        address.city = "Atlanta"
        contact.postalAddresses = [CNLabeledValue(label: CNLabelWork, value: address)]
        contact.birthday = DateComponents(year: 1980, month: 6, day: 22)
        return contact
    }

    @Test func roundTripPreservesValuesAndIdentifiers() {
        let contact = sampleContact()
        let originalPhoneIDs = contact.phoneNumbers.map(\.identifier)
        let draft = ContactDraft(contact: contact)

        #expect(draft.givenName == "John")
        #expect(draft.phoneNumbers.map(\.value) == ["888-555-5512", "888-555-1212"])
        #expect(draft.postalAddresses.first?.value.city == "Atlanta")
        #expect(draft.birthday?.includesYear == true)

        draft.apply(to: contact)
        #expect(contact.phoneNumbers.map(\.identifier) == originalPhoneIDs)
        #expect(contact.birthday?.year == 1980)
    }

    @Test func editsRemovalsAndAdditionsApply() {
        let contact = sampleContact()
        let keptID = contact.phoneNumbers[0].identifier
        var draft = ContactDraft(contact: contact)

        draft.familyName = "  Seed  "
        draft.phoneNumbers.removeLast()
        draft.phoneNumbers[0].value = "(888) 555-0000"
        draft.phoneNumbers[0].label = "Burner"
        draft.emailAddresses.append(LabeledEntry(label: CNLabelHome, value: "j@home.example"))
        draft.emailAddresses.append(LabeledEntry(label: CNLabelOther, value: "   "))  // blank: dropped
        draft.birthday = nil
        draft.apply(to: contact)

        #expect(contact.familyName == "Seed")
        #expect(contact.phoneNumbers.count == 1)
        #expect(contact.phoneNumbers[0].identifier == keptID)
        #expect(contact.phoneNumbers[0].label == "Burner")
        #expect(contact.phoneNumbers[0].value.stringValue == "(888) 555-0000")
        #expect(contact.emailAddresses.map { $0.value as String } == ["john@example.com", "j@home.example"])
        #expect(contact.birthday == nil)
    }

    @Test func hasContentRequiresSomethingIdentifying() {
        var draft = ContactDraft()
        #expect(!draft.hasContent)
        draft.jobTitle = "Engineer"
        #expect(!draft.hasContent)
        draft.emailAddresses = [LabeledEntry(label: nil, value: "a@b.c")]
        #expect(draft.hasContent)
    }

    @Test func summaryUsesOrganizationForCompanies() {
        let contact = sampleContact()
        contact.contactType = .organization
        let summary = ContactsRepository.summary(for: contact, sortOrder: .familyName)
        #expect(summary.displayName == "Apple")
        #expect(summary.sortName == "Apple")
        #expect(summary.subtitle == "John Appleseed")
        #expect(summary.isOrganization)
    }

    @Test func summarySortsByConfiguredNameOrder() {
        let contact = sampleContact()
        #expect(ContactsRepository.summary(for: contact, sortOrder: .familyName).sortName == "Appleseed")
        #expect(ContactsRepository.summary(for: contact, sortOrder: .givenName).sortName == "John")
        #expect(ContactsRepository.summary(for: contact, sortOrder: .familyName).initials == "JA")
    }
}
