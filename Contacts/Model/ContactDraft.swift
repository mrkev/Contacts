import Contacts
import Foundation

/// One entry in a multi-value field such as phone numbers. `id` is the
/// `CNLabeledValue.identifier` for existing values so edits preserve identity on save.
nonisolated struct LabeledEntry<Value: Hashable & Sendable>: Identifiable, Hashable, Sendable {
    var id: String = UUID().uuidString
    var label: String?
    var value: Value
}

nonisolated struct PostalAddressDraft: Hashable, Sendable {
    var street = ""
    var city = ""
    var state = ""
    var postalCode = ""
    var country = ""

    var isEmpty: Bool {
        [street, city, state, postalCode, country].allSatisfy { $0.nilIfBlank == nil }
    }
}

nonisolated struct BirthdayDraft: Hashable, Sendable {
    var date: Date
    var includesYear: Bool

    init(date: Date = .now, includesYear: Bool = true) {
        self.date = date
        self.includesYear = includesYear
    }

    init?(components: DateComponents?) {
        guard let components, let month = components.month, let day = components.day else { return nil }
        let year = components.year.flatMap { $0 == NSDateComponentUndefined ? nil : $0 }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        guard let date = calendar.date(from: DateComponents(year: year ?? 2000, month: month, day: day)) else {
            return nil
        }
        self.init(date: date, includesYear: year != nil)
    }

    var components: DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return DateComponents(year: includesYear ? parts.year : nil, month: parts.month, day: parts.day)
    }
}

/// Editable, `Sendable` copy of the contact fields this app lets you change.
/// Built from a `CNContact`, edited by the UI, then applied back onto a `CNMutableContact`.
nonisolated struct ContactDraft: Hashable, Sendable {
    var isOrganization = false

    var namePrefix = ""
    var givenName = ""
    var middleName = ""
    var familyName = ""
    var nameSuffix = ""
    var nickname = ""
    var phoneticGivenName = ""
    var phoneticFamilyName = ""

    var organizationName = ""
    var departmentName = ""
    var jobTitle = ""

    var phoneNumbers: [LabeledEntry<String>] = []
    var emailAddresses: [LabeledEntry<String>] = []
    var urlAddresses: [LabeledEntry<String>] = []
    var postalAddresses: [LabeledEntry<PostalAddressDraft>] = []
    var relations: [LabeledEntry<String>] = []

    var birthday: BirthdayDraft?

    var imageData: Data?
    var imageChanged = false

    init() {}

    /// Keys that must be fetched on a contact before `init(contact:)` or `apply(to:)` is used with it.
    static let requiredKeys: [CNKeyDescriptor] = [
        CNContactTypeKey, CNContactNamePrefixKey, CNContactGivenNameKey, CNContactMiddleNameKey,
        CNContactFamilyNameKey, CNContactNameSuffixKey, CNContactNicknameKey,
        CNContactPhoneticGivenNameKey, CNContactPhoneticFamilyNameKey,
        CNContactOrganizationNameKey, CNContactDepartmentNameKey, CNContactJobTitleKey,
        CNContactPhoneNumbersKey, CNContactEmailAddressesKey, CNContactUrlAddressesKey,
        CNContactPostalAddressesKey, CNContactRelationsKey, CNContactBirthdayKey,
        CNContactImageDataKey, CNContactImageDataAvailableKey,
    ] as [CNKeyDescriptor]

    init(contact: CNContact) {
        isOrganization = contact.contactType == .organization
        namePrefix = contact.namePrefix
        givenName = contact.givenName
        middleName = contact.middleName
        familyName = contact.familyName
        nameSuffix = contact.nameSuffix
        nickname = contact.nickname
        phoneticGivenName = contact.phoneticGivenName
        phoneticFamilyName = contact.phoneticFamilyName
        organizationName = contact.organizationName
        departmentName = contact.departmentName
        jobTitle = contact.jobTitle

        phoneNumbers = contact.phoneNumbers.map { .init(id: $0.identifier, label: $0.label, value: $0.value.stringValue) }
        emailAddresses = contact.emailAddresses.map { .init(id: $0.identifier, label: $0.label, value: $0.value as String) }
        urlAddresses = contact.urlAddresses.map { .init(id: $0.identifier, label: $0.label, value: $0.value as String) }
        relations = contact.contactRelations.map { .init(id: $0.identifier, label: $0.label, value: $0.value.name) }
        postalAddresses = contact.postalAddresses.map {
            let address = $0.value
            return .init(id: $0.identifier, label: $0.label, value: PostalAddressDraft(
                street: address.street, city: address.city, state: address.state,
                postalCode: address.postalCode, country: address.country))
        }
        birthday = BirthdayDraft(components: contact.birthday)
        imageData = contact.imageDataAvailable ? contact.imageData : nil
    }

    /// True when there is at least something to identify the contact by.
    var hasContent: Bool {
        [givenName, familyName, middleName, nickname, organizationName].contains { $0.nilIfBlank != nil }
            || phoneNumbers.contains { $0.value.nilIfBlank != nil }
            || emailAddresses.contains { $0.value.nilIfBlank != nil }
    }

    /// Copies the draft onto `contact`, keeping identifiers of labeled values that still exist.
    func apply(to contact: CNMutableContact) {
        contact.contactType = isOrganization ? .organization : .person
        contact.namePrefix = namePrefix.trimmed
        contact.givenName = givenName.trimmed
        contact.middleName = middleName.trimmed
        contact.familyName = familyName.trimmed
        contact.nameSuffix = nameSuffix.trimmed
        contact.nickname = nickname.trimmed
        contact.phoneticGivenName = phoneticGivenName.trimmed
        contact.phoneticFamilyName = phoneticFamilyName.trimmed
        contact.organizationName = organizationName.trimmed
        contact.departmentName = departmentName.trimmed
        contact.jobTitle = jobTitle.trimmed

        contact.phoneNumbers = Self.merge(phoneNumbers, into: contact.phoneNumbers,
                                          isEmpty: { $0.nilIfBlank == nil },
                                          make: { CNPhoneNumber(stringValue: $0.trimmed) })
        contact.emailAddresses = Self.merge(emailAddresses, into: contact.emailAddresses,
                                            isEmpty: { $0.nilIfBlank == nil },
                                            make: { $0.trimmed as NSString })
        contact.urlAddresses = Self.merge(urlAddresses, into: contact.urlAddresses,
                                          isEmpty: { $0.nilIfBlank == nil },
                                          make: { $0.trimmed as NSString })
        contact.contactRelations = Self.merge(relations, into: contact.contactRelations,
                                              isEmpty: { $0.nilIfBlank == nil },
                                              make: { CNContactRelation(name: $0.trimmed) })
        contact.postalAddresses = Self.merge(postalAddresses, into: contact.postalAddresses,
                                             isEmpty: \.isEmpty,
                                             make: { draft in
            let address = CNMutablePostalAddress()
            address.street = draft.street.trimmed
            address.city = draft.city.trimmed
            address.state = draft.state.trimmed
            address.postalCode = draft.postalCode.trimmed
            address.country = draft.country.trimmed
            return address.copy() as! CNPostalAddress
        })

        contact.birthday = birthday?.components
        if imageChanged {
            contact.imageData = imageData
        }
    }

    private static func merge<V, C>(
        _ entries: [LabeledEntry<V>],
        into existing: [CNLabeledValue<C>],
        isEmpty: (V) -> Bool,
        make: (V) -> C
    ) -> [CNLabeledValue<C>] {
        let existingByID = Dictionary(existing.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        return entries.filter { !isEmpty($0.value) }.map { entry in
            if let original = existingByID[entry.id] {
                return original.settingLabel(entry.label, value: make(entry.value))
            }
            return CNLabeledValue(label: entry.label, value: make(entry.value))
        }
    }
}

nonisolated extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
