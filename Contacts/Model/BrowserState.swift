import SwiftUI
import UniformTypeIdentifiers

/// Per-window navigation and presentation state. Exposed to menu commands via `focusedSceneValue`.
@Observable
final class BrowserState {
    var sidebarSelection: SidebarItem? = .allContacts
    var selection: Set<String> = []
    var searchText = ""
    var preferredCompactColumn: NavigationSplitViewColumn = .content

    var editor: EditorRequest?
    var groupPrompt: GroupPrompt?
    var pendingDeletion: PendingDeletion?
    var isImporting = false
    var pendingImport: PendingImport?
    var export: VCardExportFile?

    var selectedContactID: String? {
        selection.count == 1 ? selection.first : nil
    }

    var currentGroupID: String? {
        if case .group(let id) = sidebarSelection { id } else { nil }
    }

    func newContact(in model: ContactsModel) {
        editor = EditorRequest(
            contactID: nil,
            containerID: model.targetContainerID(for: sidebarSelection),
            groupID: currentGroupID)
    }

    func edit(_ id: String) {
        editor = EditorRequest(contactID: id, containerID: nil, groupID: nil)
    }

    func newGroup(in model: ContactsModel) {
        groupPrompt = GroupPrompt(groupID: nil, containerID: model.targetContainerID(for: sidebarSelection), name: "")
    }

    func confirmDelete(_ ids: Set<String>, model: ContactsModel) {
        guard !ids.isEmpty else { return }
        let name = ids.count == 1 ? ids.first.flatMap { model.summary($0)?.displayName } : nil
        pendingDeletion = PendingDeletion(ids: ids, singleName: name)
    }

    func exportVCards(_ ids: [String], model: ContactsModel) async {
        guard !ids.isEmpty else { return }
        do {
            let data = try await model.repository.vCardData(for: ids)
            let name = ids.count == 1 ? model.summary(ids[0])?.displayName : nil
            export = VCardExportFile(data: data, filename: name ?? String(localized: "\(ids.count) Contacts"))
        } catch {
            model.error = AppError(String(localized: "Couldn’t Export Contacts"), error)
        }
    }
}

struct EditorRequest: Identifiable {
    let id = UUID()
    var contactID: String?
    var containerID: String?
    var groupID: String?
}

struct GroupPrompt: Identifiable {
    let id = UUID()
    /// nil when creating a new group.
    var groupID: String?
    var containerID: String?
    var name: String
}

struct PendingDeletion: Identifiable {
    let id = UUID()
    var ids: Set<String>
    var singleName: String?

    var title: String {
        if let singleName { String(localized: "Delete “\(singleName)”?") }
        else { String(localized: "Delete \(ids.count) Contacts?") }
    }
}

struct PendingImport: Identifiable {
    let id = UUID()
    var urls: [URL]
    var names: [String]
}

struct VCardExportFile: Identifiable {
    let id = UUID()
    var data: Data
    var filename: String
}

extension FocusedValues {
    @Entry var browser: BrowserState?
}
