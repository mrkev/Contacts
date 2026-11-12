import Contacts
import Observation
import SwiftUI

/// What the sidebar can show in the contact list.
enum SidebarItem: Hashable, Sendable {
    case allContacts
    case birthdays
    case container(String)
    case group(String)
}

enum ContactsAccess: Equatable {
    case notDetermined, denied, restricted, limited, authorized

    init(_ status: CNAuthorizationStatus) {
        switch status {
        case .authorized: self = .authorized
        case .denied: self = .denied
        case .restricted: self = .restricted
        case .notDetermined: self = .notDetermined
        default:
            #if os(iOS)
            self = status == .limited ? .limited : .denied
            #else
            self = .denied
            #endif
        }
    }

    var canRead: Bool { self == .authorized || self == .limited }
}

struct AppError: Identifiable {
    let id = UUID()
    var title: String
    var message: String

    init(_ title: String, _ error: Error) {
        self.title = title
        self.message = error.localizedDescription
    }
}

/// App-wide state backed by the system contact store. Mirrors the store into
/// `Sendable` snapshots and reloads whenever the store changes (from this app or elsewhere).
@Observable
final class ContactsModel {
    private(set) var access = ContactsAccess(ContactsRepository.authorizationStatus)
    private(set) var snapshot = ContactsSnapshot()
    private(set) var hasLoaded = false
    private(set) var isLoading = false
    /// Bumps on every reload so views showing full contacts know to refetch.
    private(set) var revision = 0
    var error: AppError?

    let repository = ContactsRepository.shared
    @ObservationIgnored private var changeObserver: Task<Void, Never>?
    @ObservationIgnored private var pendingReload: Task<Void, Never>?

    init() {
        changeObserver = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .CNContactStoreDidChange) {
                self?.scheduleReload()
            }
        }
    }

    // MARK: Derived data

    var contacts: [ContactSummary] { snapshot.contacts }
    var containers: [ContainerInfo] { snapshot.containers }
    var groups: [GroupInfo] { snapshot.groups }
    var meContactID: String? { snapshot.meContactID }
    var defaultContainerID: String? { snapshot.defaultContainerID }

    func groups(in containerID: String) -> [GroupInfo] {
        groups.filter { $0.containerID == containerID }
    }

    func group(_ id: String) -> GroupInfo? { groups.first { $0.id == id } }
    func container(_ id: String) -> ContainerInfo? { containers.first { $0.id == id } }
    func summary(_ id: String) -> ContactSummary? { contacts.first { $0.id == id } }

    func groupIDs(containing contactID: String) -> [String] {
        groups.map(\.id).filter { snapshot.groupMembers[$0]?.contains(contactID) == true }
    }

    func contacts(in item: SidebarItem, matching query: String = "") -> [ContactSummary] {
        let scoped: [ContactSummary] = switch item {
        case .allContacts, .birthdays:
            contacts
        case .container(let id):
            contacts.filter { snapshot.containerMembers[id]?.contains($0.id) == true }
        case .group(let id):
            contacts.filter { snapshot.groupMembers[id]?.contains($0.id) == true }
        }
        let trimmed = query.trimmed
        return trimmed.isEmpty ? scoped : scoped.filter { $0.matches(trimmed) }
    }

    func title(for item: SidebarItem) -> String {
        switch item {
        case .allContacts: String(localized: "All Contacts")
        case .birthdays: String(localized: "Birthdays")
        case .container(let id): container(id)?.name ?? String(localized: "Contacts")
        case .group(let id): group(id)?.name ?? String(localized: "Group")
        }
    }

    /// Container new contacts and groups should go into for the given sidebar selection.
    func targetContainerID(for item: SidebarItem?) -> String? {
        switch item {
        case .container(let id): id
        case .group(let id): group(id)?.containerID ?? defaultContainerID
        default: defaultContainerID
        }
    }

    // MARK: Access

    func refreshAccess() {
        let newAccess = ContactsAccess(ContactsRepository.authorizationStatus)
        if newAccess != access {
            access = newAccess
            hasLoaded = false
        }
        if access.canRead, !hasLoaded {
            Task { await reload() }
        }
    }

    func requestAccess() async {
        do {
            _ = try await repository.requestAccess()
        } catch {
            self.error = AppError(String(localized: "Couldn’t Request Access"), error)
        }
        refreshAccess()
    }

    // MARK: Loading

    func reload() async {
        guard access.canRead else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            snapshot = try await repository.loadSnapshot()
            hasLoaded = true
            revision += 1
            ThumbnailCache.shared.removeAll()
        } catch {
            self.error = AppError(String(localized: "Couldn’t Load Contacts"), error)
        }
    }

    /// Coalesces bursts of change notifications (a single save can post several).
    private func scheduleReload() {
        pendingReload?.cancel()
        pendingReload = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await reload()
        }
    }

    // MARK: Mutations

    func contact(_ id: String) throws -> CNContact {
        try repository.contact(withID: id)
    }

    @discardableResult
    func save(_ draft: ContactDraft, contactID: String?, containerID: String?, groupID: String?) async -> String? {
        await perform(String(localized: "Couldn’t Save Contact")) {
            try await repository.save(draft, contactID: contactID, containerID: containerID, groupID: groupID)
        }
    }

    func delete(_ ids: Set<String>) async {
        await perform(String(localized: "Couldn’t Delete Contact")) {
            try await repository.deleteContacts(ids)
        }
    }

    @discardableResult
    func createGroup(named name: String, containerID: String?) async -> String? {
        await perform(String(localized: "Couldn’t Create Group")) {
            try await repository.createGroup(named: name, containerID: containerID)
        }
    }

    func renameGroup(_ id: String, to name: String) async {
        await perform(String(localized: "Couldn’t Rename Group")) {
            try await repository.renameGroup(id, to: name)
        }
    }

    func deleteGroup(_ id: String) async {
        await perform(String(localized: "Couldn’t Delete Group")) {
            try await repository.deleteGroup(id)
        }
    }

    func setMembership(_ ids: Set<String>, group: String, isMember: Bool) async {
        await perform(String(localized: "Couldn’t Update Group")) {
            try await repository.setMembership(ids, group: group, isMember: isMember)
        }
    }

    func importVCards(at urls: [URL], containerID: String?, groupID: String?) async -> Int? {
        await perform(String(localized: "Couldn’t Import Contacts")) {
            try await repository.importVCards(at: urls, containerID: containerID, groupID: groupID)
        }
    }

    /// Runs a store write, surfaces failures as an alert, and reloads immediately on success
    /// so the UI doesn't wait for the change notification.
    private func perform<T>(_ failureTitle: String, _ operation: () async throws -> T) async -> T? {
        do {
            let result = try await operation()
            await reload()
            return result
        } catch {
            self.error = AppError(failureTitle, error)
            return nil
        }
    }
}
