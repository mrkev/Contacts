import Contacts
import Foundation
import Testing
@testable import ContactsApp

#if targetEnvironment(simulator)
/// Exercises the real `CNContactStore`. Simulator-only so it never touches a real address book.
/// Grant access first: `xcrun simctl privacy booted grant contacts com.aykev.Contacts`
@Suite(.serialized, .enabled(if: CNContactStore.authorizationStatus(for: .contacts) == .authorized))
struct StoreIntegrationTests {
    let repository = ContactsRepository.shared

    @Test func snapshotLoadsAndEveryDetailFetchSucceeds() async throws {
        let snapshot = try await repository.loadSnapshot()
        #expect(!snapshot.contacts.isEmpty)
        #expect(!snapshot.containers.isEmpty)
        for summary in snapshot.contacts {
            // Fails loudly if the card reads a key we didn't fetch.
            let contact = try repository.contact(withID: summary.id)
            _ = ContactDraft(contact: contact)
            _ = CNContactFormatter.string(from: contact, style: .fullName)
        }
    }

    @Test func vCardExportAndParse() async throws {
        let snapshot = try await repository.loadSnapshot()
        let ids = snapshot.contacts.prefix(3).map(\.id)
        let data = try await repository.vCardData(for: ids)
        let parsed = try CNContactVCardSerialization.contacts(with: data)
        #expect(parsed.count == ids.count)
    }

    @Test func createEditGroupAndDeleteContact() async throws {
        var draft = ContactDraft()
        draft.givenName = "Integration"
        draft.familyName = "Test \(UUID().uuidString.prefix(6))"
        draft.phoneNumbers = [LabeledEntry(label: CNLabelPhoneNumberMobile, value: "555-0100")]
        draft.birthday = BirthdayDraft(components: DateComponents(month: 3, day: 14))

        let id = try await repository.save(draft, contactID: nil, containerID: nil, groupID: nil)
        defer { Task { try? await repository.deleteContacts([id]) } }

        var edited = ContactDraft(contact: try repository.contact(withID: id))
        #expect(edited.birthday?.includesYear == false)
        edited.emailAddresses = [LabeledEntry(label: CNLabelWork, value: "it@example.com")]
        edited.phoneNumbers[0].value = "555-0199"
        _ = try await repository.save(edited, contactID: id, containerID: nil, groupID: nil)

        let reloaded = try repository.contact(withID: id)
        #expect(reloaded.phoneNumbers.map { $0.value.stringValue } == ["555-0199"])
        #expect(reloaded.emailAddresses.map { $0.value as String } == ["it@example.com"])

        let groupID = try await repository.createGroup(named: "IT Group \(UUID().uuidString.prefix(4))", containerID: nil)
        try await repository.setMembership([id], group: groupID, isMember: true)
        var snapshot = try await repository.loadSnapshot()
        #expect(snapshot.groupMembers[groupID] == [id])

        try await repository.deleteGroup(groupID)
        try await repository.deleteContacts([id])
        snapshot = try await repository.loadSnapshot()
        #expect(!snapshot.contacts.contains { $0.id == id })
        #expect(!snapshot.groups.contains { $0.id == groupID })
    }
}
#endif
