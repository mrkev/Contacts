import Foundation

/// Lightweight, `Sendable` projection of a `CNContact` used by lists, search, and sidebars.
/// Full contact details are fetched on demand when a contact is shown or edited.
nonisolated struct ContactSummary: Identifiable, Hashable, Sendable {
    var id: String
    var displayName: String
    /// The name the system sorts by (family or given name, per the user's Contacts settings).
    var sortName: String
    var subtitle: String?
    var initials: String
    var isOrganization: Bool
    var hasImage: Bool
    var birthday: DateComponents?
    var phoneNumbers: [String]
    var emailAddresses: [String]

    /// Case- and diacritic-folded text used for matching search terms.
    var searchText: String
    /// Digits from every phone number, so "5551234" matches "(555) 123-4".
    var phoneDigits: [String]

    init(
        id: String,
        displayName: String,
        sortName: String,
        subtitle: String? = nil,
        initials: String,
        isOrganization: Bool = false,
        hasImage: Bool = false,
        birthday: DateComponents? = nil,
        phoneNumbers: [String] = [],
        emailAddresses: [String] = [],
        extraSearchTerms: [String] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.sortName = sortName
        self.subtitle = subtitle
        self.initials = initials
        self.isOrganization = isOrganization
        self.hasImage = hasImage
        self.birthday = birthday
        self.phoneNumbers = phoneNumbers
        self.emailAddresses = emailAddresses
        self.searchText = ([displayName, subtitle ?? ""] + emailAddresses + extraSearchTerms)
            .joined(separator: " ")
            .searchFolded
        self.phoneDigits = phoneNumbers.map(\.digitsOnly).filter { !$0.isEmpty }
    }

    /// Index letter for the alphabetical section this contact belongs in ("#" for non-letters).
    var sectionTitle: String {
        guard let first = sortName.trimmingCharacters(in: .whitespacesAndNewlines).first else { return "#" }
        let folded = String(first).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).uppercased()
        return first.isLetter ? folded : "#"
    }

    /// Returns true when every whitespace-separated term in `query` matches this contact.
    func matches(_ query: String) -> Bool {
        let terms = query.searchFolded.split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return true }
        return terms.allSatisfy { term in
            if searchText.contains(term) { return true }
            let digits = String(term).digitsOnly
            let isPhoneLike = digits.count >= 3 && term.allSatisfy { $0.isNumber || "()-+.".contains($0) }
            return isPhoneLike && phoneDigits.contains { $0.contains(digits) }
        }
    }
}

nonisolated struct ContactSection: Identifiable, Hashable, Sendable {
    var title: String
    var contacts: [ContactSummary]
    var id: String { title }

    /// Groups already-sorted contacts into alphabetical sections, keeping their order
    /// within each section and placing "#" last, as the system Contacts app does.
    static func sections(for contacts: [ContactSummary]) -> [ContactSection] {
        var order: [String] = []
        var buckets: [String: [ContactSummary]] = [:]
        for contact in contacts {
            let title = contact.sectionTitle
            if buckets[title] == nil { order.append(title) }
            buckets[title, default: []].append(contact)
        }
        let sortedTitles = order.sorted { lhs, rhs in
            if lhs == "#" { return false }
            if rhs == "#" { return true }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        return sortedTitles.map { ContactSection(title: $0, contacts: buckets[$0] ?? []) }
    }
}

nonisolated extension String {
    var searchFolded: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
    }

    var digitsOnly: String {
        String(unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.map(Character.init))
    }

    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
