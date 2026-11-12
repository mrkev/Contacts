import Contacts
import Foundation

nonisolated struct ContainerInfo: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var type: CNContainerType
}

nonisolated struct GroupInfo: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var containerID: String?
}

/// Everything the browser needs to render lists and sidebars, loaded in one pass.
nonisolated struct ContactsSnapshot: Sendable {
    var contacts: [ContactSummary] = []
    var containers: [ContainerInfo] = []
    var defaultContainerID: String?
    var groups: [GroupInfo] = []
    var groupMembers: [String: Set<String>] = [:]
    var containerMembers: [String: Set<String>] = [:]
    var meContactID: String?
}

/// Thin wrapper over `CNContactStore`. `CNContactStore` is thread-safe; heavy reads run
/// off the main actor via `@concurrent` and return `Sendable` value types.
nonisolated final class ContactsRepository: @unchecked Sendable {
    static let shared = ContactsRepository()

    let store = CNContactStore()

    // MARK: Authorization

    static var authorizationStatus: CNAuthorizationStatus {
        CNContactStore.authorizationStatus(for: .contacts)
    }

    func requestAccess() async throws -> Bool {
        try await store.requestAccess(for: .contacts)
    }

    // MARK: Reading

    static let summaryKeys: [CNKeyDescriptor] = [
        CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
        CNContactIdentifierKey as CNKeyDescriptor,
        CNContactTypeKey as CNKeyDescriptor,
        CNContactNamePrefixKey as CNKeyDescriptor,
        CNContactNameSuffixKey as CNKeyDescriptor,
        CNContactGivenNameKey as CNKeyDescriptor,
        CNContactFamilyNameKey as CNKeyDescriptor,
        CNContactNicknameKey as CNKeyDescriptor,
        CNContactOrganizationNameKey as CNKeyDescriptor,
        CNContactDepartmentNameKey as CNKeyDescriptor,
        CNContactJobTitleKey as CNKeyDescriptor,
        CNContactImageDataAvailableKey as CNKeyDescriptor,
        CNContactBirthdayKey as CNKeyDescriptor,
        CNContactPhoneNumbersKey as CNKeyDescriptor,
        CNContactEmailAddressesKey as CNKeyDescriptor,
    ]

    /// Every key the detail card displays. Notes are deliberately excluded: reading them
    /// requires the `com.apple.developer.contacts.notes` entitlement.
    static let detailKeys: [CNKeyDescriptor] = summaryKeys + ContactDraft.requiredKeys + ([
        CNContactPreviousFamilyNameKey, CNContactPhoneticMiddleNameKey, CNContactPhoneticOrganizationNameKey,
        CNContactDatesKey, CNContactNonGregorianBirthdayKey, CNContactSocialProfilesKey,
        CNContactInstantMessageAddressesKey, CNContactThumbnailImageDataKey,
    ] as [CNKeyDescriptor])

    @concurrent
    func loadSnapshot() async throws -> ContactsSnapshot {
        var snapshot = ContactsSnapshot()
        let sortOrder = CNContactsUserDefaults.shared().sortOrder

        let request = CNContactFetchRequest(keysToFetch: Self.summaryKeys)
        request.sortOrder = .userDefault
        var contacts: [ContactSummary] = []
        try store.enumerateContacts(with: request) { contact, _ in
            contacts.append(Self.summary(for: contact, sortOrder: sortOrder))
        }
        snapshot.contacts = contacts

        let containers = try store.containers(matching: nil)
        snapshot.containers = containers
            .map { ContainerInfo(id: $0.identifier, name: Self.displayName(for: $0), type: $0.type) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        snapshot.defaultContainerID = store.defaultContainerIdentifier()

        for container in containers {
            snapshot.containerMembers[container.identifier] = try memberIDs(
                matching: CNContact.predicateForContactsInContainer(withIdentifier: container.identifier))
            let groups = try store.groups(matching: CNGroup.predicateForGroupsInContainer(withIdentifier: container.identifier))
            for group in groups {
                snapshot.groups.append(GroupInfo(id: group.identifier, name: group.name, containerID: container.identifier))
            }
        }
        snapshot.groups.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        for group in snapshot.groups {
            snapshot.groupMembers[group.id] = try memberIDs(
                matching: CNContact.predicateForContactsInGroup(withIdentifier: group.id))
        }

        #if os(macOS)
        snapshot.meContactID = (try? store.unifiedMeContactWithKeys(toFetch: [CNContactIdentifierKey as CNKeyDescriptor]))?.identifier
        #endif
        return snapshot
    }

    private func memberIDs(matching predicate: NSPredicate) throws -> Set<String> {
        let request = CNContactFetchRequest(keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor])
        request.predicate = predicate
        var ids = Set<String>()
        try store.enumerateContacts(with: request) { contact, _ in ids.insert(contact.identifier) }
        return ids
    }

    func contact(withID id: String, keys: [CNKeyDescriptor] = detailKeys) throws -> CNContact {
        try store.unifiedContact(withIdentifier: id, keysToFetch: keys)
    }

    @concurrent
    func thumbnailData(for id: String) async -> Data? {
        let keys = [CNContactThumbnailImageDataKey as CNKeyDescriptor]
        return try? store.unifiedContact(withIdentifier: id, keysToFetch: keys).thumbnailImageData
    }

    // MARK: Writing contacts

    /// Creates or updates a contact from a draft and returns its identifier.
    @concurrent
    func save(_ draft: ContactDraft, contactID: String?, containerID: String?, groupID: String?) async throws -> String {
        let request = CNSaveRequest()
        let mutable: CNMutableContact
        if let contactID {
            mutable = try store.unifiedContact(withIdentifier: contactID, keysToFetch: ContactDraft.requiredKeys)
                .mutableCopy() as! CNMutableContact
            draft.apply(to: mutable)
            request.update(mutable)
        } else {
            mutable = CNMutableContact()
            draft.apply(to: mutable)
            request.add(mutable, toContainerWithIdentifier: containerID)
            if let groupID, let group = try group(withID: groupID) {
                request.addMember(mutable, to: group)
            }
        }
        try store.execute(request)
        return mutable.identifier
    }

    @concurrent
    func deleteContacts(_ ids: Set<String>) async throws {
        guard !ids.isEmpty else { return }
        let request = CNSaveRequest()
        for contact in try contacts(withIDs: ids, keys: [CNContactIdentifierKey as CNKeyDescriptor]) {
            request.delete(contact.mutableCopy() as! CNMutableContact)
        }
        try store.execute(request)
    }

    private func contacts(withIDs ids: Set<String>, keys: [CNKeyDescriptor]) throws -> [CNContact] {
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.predicate = CNContact.predicateForContacts(withIdentifiers: Array(ids))
        var result: [CNContact] = []
        try store.enumerateContacts(with: request) { contact, _ in result.append(contact) }
        return result
    }

    // MARK: Groups

    private func group(withID id: String) throws -> CNGroup? {
        try store.groups(matching: CNGroup.predicateForGroups(withIdentifiers: [id])).first
    }

    @concurrent
    func createGroup(named name: String, containerID: String?) async throws -> String {
        let group = CNMutableGroup()
        group.name = name
        let request = CNSaveRequest()
        request.add(group, toContainerWithIdentifier: containerID)
        try store.execute(request)
        return group.identifier
    }

    @concurrent
    func renameGroup(_ id: String, to name: String) async throws {
        guard let group = try group(withID: id)?.mutableCopy() as? CNMutableGroup else { return }
        group.name = name
        let request = CNSaveRequest()
        request.update(group)
        try store.execute(request)
    }

    @concurrent
    func deleteGroup(_ id: String) async throws {
        guard let group = try group(withID: id)?.mutableCopy() as? CNMutableGroup else { return }
        let request = CNSaveRequest()
        request.delete(group)
        try store.execute(request)
    }

    @concurrent
    func setMembership(_ ids: Set<String>, group groupID: String, isMember: Bool) async throws {
        guard let group = try group(withID: groupID) else { return }
        let request = CNSaveRequest()
        for contact in try contacts(withIDs: ids, keys: [CNContactIdentifierKey as CNKeyDescriptor]) {
            if isMember {
                request.addMember(contact, to: group)
            } else {
                request.removeMember(contact, from: group)
            }
        }
        try store.execute(request)
    }

    // MARK: vCard

    @concurrent
    func vCardData(for ids: [String]) async throws -> Data {
        let keys = [CNContactVCardSerialization.descriptorForRequiredKeys()]
        let fetched = try contacts(withIDs: Set(ids), keys: keys)
        // Preserve the caller's order (usually list order).
        let order = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        let sorted = fetched.sorted { (order[$0.identifier] ?? .max) < (order[$1.identifier] ?? .max) }
        return try CNContactVCardSerialization.data(with: sorted)
    }

    /// Parses vCard files and returns the names of the contacts found, without saving.
    @concurrent
    func previewVCards(at urls: [URL]) async throws -> [String] {
        try parseVCards(at: urls).map { contact in
            CNContactFormatter.string(from: contact, style: .fullName)
                ?? contact.organizationName.nilIfBlank
                ?? (contact.emailAddresses.first?.value as String?)
                ?? String(localized: "No Name")
        }
    }

    @concurrent
    func importVCards(at urls: [URL], containerID: String?, groupID: String?) async throws -> Int {
        let parsed = try parseVCards(at: urls)
        guard !parsed.isEmpty else { return 0 }
        let request = CNSaveRequest()
        let group = try groupID.flatMap { try self.group(withID: $0) }
        for contact in parsed {
            let mutable = contact.mutableCopy() as! CNMutableContact
            request.add(mutable, toContainerWithIdentifier: containerID)
            if let group { request.addMember(mutable, to: group) }
        }
        try store.execute(request)
        return parsed.count
    }

    private func parseVCards(at urls: [URL]) throws -> [CNContact] {
        try urls.flatMap { url -> [CNContact] in
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            return try CNContactVCardSerialization.contacts(with: Data(contentsOf: url))
        }
    }

    // MARK: Helpers

    static func summary(for contact: CNContact, sortOrder: CNContactSortOrder) -> ContactSummary {
        let isOrganization = contact.contactType == .organization
        let fullName = CNContactFormatter.string(from: contact, style: .fullName)?.nilIfBlank
        let email = contact.emailAddresses.first.map { $0.value as String }
        let phone = contact.phoneNumbers.first?.value.stringValue
        let organization = contact.organizationName.nilIfBlank

        let displayName = (isOrganization ? organization ?? fullName : fullName ?? organization)
            ?? email ?? phone ?? String(localized: "No Name")

        let sortName: String
        if isOrganization {
            sortName = organization ?? displayName
        } else if sortOrder == .givenName {
            sortName = contact.givenName.nilIfBlank ?? contact.familyName.nilIfBlank ?? displayName
        } else {
            sortName = contact.familyName.nilIfBlank ?? contact.givenName.nilIfBlank ?? displayName
        }

        // For companies, CNContactFormatter returns the organization name, so format the person's name directly.
        let personName = PersonNameComponents(
            namePrefix: contact.namePrefix.nilIfBlank, givenName: contact.givenName.nilIfBlank,
            familyName: contact.familyName.nilIfBlank, nameSuffix: contact.nameSuffix.nilIfBlank
        ).formatted(.name(style: .medium)).nilIfBlank
        let subtitle: String? = isOrganization
            ? personName.flatMap { $0 == displayName ? nil : $0 }
            : [contact.jobTitle.nilIfBlank, organization].compactMap { $0 }.joined(separator: ", ").nilIfBlank

        return ContactSummary(
            id: contact.identifier,
            displayName: displayName,
            sortName: sortName,
            subtitle: subtitle,
            initials: initials(given: contact.givenName, family: contact.familyName,
                               fallback: isOrganization ? organization ?? displayName : displayName),
            isOrganization: isOrganization,
            hasImage: contact.imageDataAvailable,
            birthday: contact.birthday,
            phoneNumbers: contact.phoneNumbers.map { $0.value.stringValue },
            emailAddresses: contact.emailAddresses.map { $0.value as String },
            extraSearchTerms: [contact.nickname, contact.departmentName].compactMap(\.nilIfBlank)
        )
    }

    static func initials(given: String, family: String, fallback: String) -> String {
        let parts = [given, family].compactMap { $0.trimmed.first }
        if !parts.isEmpty { return String(parts).uppercased() }
        return fallback.trimmed.first.map { String($0).uppercased() } ?? ""
    }

    private static func displayName(for container: CNContainer) -> String {
        if let name = container.name.nilIfBlank { return name }
        return switch container.type {
        case .local: String(localized: "On My Device")
        case .exchange: String(localized: "Exchange")
        case .cardDAV: String(localized: "CardDAV")
        default: String(localized: "Contacts")
        }
    }
}
