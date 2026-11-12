import SwiftUI
import UniformTypeIdentifiers

/// Three-column browser: sources sidebar → contact list → contact card.
/// Owns the per-window sheets, dialogs, and file panels.
struct BrowserView: View {
    @Environment(ContactsModel.self) private var model
    @State private var browser = BrowserState()

    var body: some View {
        splitView
            .focusedSceneValue(\.browser, browser)
            .task {
                if !model.hasLoaded { await model.reload() }
            }
            // Drop selection that no longer exists (deleted here or in another app).
            .onChange(of: model.revision) {
                browser.selection.formIntersection(Set(model.contacts.map(\.id)))
                if case .group(let id) = browser.sidebarSelection, model.group(id) == nil {
                    browser.sidebarSelection = .allContacts
                }
            }
            .onChange(of: browser.sidebarSelection) { browser.selection = [] }
            .modifier(EditingPresentations(browser: browser))
            .modifier(FilePresentations(browser: browser))
            .modifier(ErrorAlert())
    }

    private var splitView: some View {
        @Bindable var browser = browser
        return NavigationSplitView(preferredCompactColumn: $browser.preferredCompactColumn) {
            SidebarView(browser: browser)
        } content: {
            ContactListView(browser: browser)
        } detail: {
            NavigationStack {
                DetailColumn(browser: browser)
            }
        }
    }
}

private func isPresenting<T>(_ binding: Binding<T?>) -> Binding<Bool> {
    Binding(get: { binding.wrappedValue != nil }, set: { if !$0 { binding.wrappedValue = nil } })
}

/// Editor sheet, group name prompt, and delete confirmation.
private struct EditingPresentations: ViewModifier {
    @Bindable var browser: BrowserState
    @Environment(ContactsModel.self) private var model

    func body(content: Content) -> some View {
        content
            .sheet(item: $browser.editor) { request in
                ContactEditorView(request: request) { savedID in
                    if let savedID { browser.selection = [savedID] }
                }
            }
            .alert(browser.groupPrompt?.groupID == nil ? "New Group" : "Rename Group",
                   isPresented: isPresenting($browser.groupPrompt)) {
                GroupPromptActions(browser: browser)
            }
            .confirmationDialog(browser.pendingDeletion?.title ?? "",
                                isPresented: isPresenting($browser.pendingDeletion),
                                titleVisibility: .visible,
                                presenting: browser.pendingDeletion) { deletion in
                Button("Delete", role: .destructive) {
                    Task { await model.delete(deletion.ids) }
                }
            } message: { _ in
                Text("This removes the contact from all your devices.")
            }
    }
}

/// vCard import (file picker → confirmation) and export.
private struct FilePresentations: ViewModifier {
    @Bindable var browser: BrowserState
    @Environment(ContactsModel.self) private var model

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $browser.isImporting, allowedContentTypes: [.vCard],
                          allowsMultipleSelection: true) { result in
                handleImportSelection(result)
            }
            .confirmationDialog(importTitle, isPresented: isPresenting($browser.pendingImport),
                                titleVisibility: .visible, presenting: browser.pendingImport) { pending in
                Button("Import") { Task { await performImport(pending) } }
            } message: { pending in
                Text(importMessage(pending))
            }
            .fileExporter(isPresented: isPresenting($browser.export),
                          document: exportDocument,
                          contentType: .vCard,
                          defaultFilename: browser.export?.filename) { result in
                if case .failure(let error) = result {
                    model.error = AppError(String(localized: "Couldn’t Export Contacts"), error)
                }
                browser.export = nil
            }
    }

    private var exportDocument: VCardDocument? {
        browser.export.map { VCardDocument(data: $0.data) }
    }

    private var importTitle: String {
        let count = browser.pendingImport?.names.count ?? 0
        if let destination = browser.currentGroupID.flatMap({ model.group($0)?.name }) {
            return String(localized: "Import \(count) Contacts into “\(destination)”?")
        }
        return String(localized: "Import \(count) Contacts?")
    }

    private func importMessage(_ pending: PendingImport) -> String {
        let shown = pending.names.prefix(5).joined(separator: "\n")
        return pending.names.count > 5 ? shown + "\n…" : shown
    }

    private func handleImportSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            Task {
                do {
                    let names = try await model.repository.previewVCards(at: urls)
                    if names.isEmpty {
                        model.error = AppError(String(localized: "Nothing to Import"), CocoaError(.fileReadCorruptFile))
                    } else {
                        browser.pendingImport = PendingImport(urls: urls, names: names)
                    }
                } catch {
                    model.error = AppError(String(localized: "Couldn’t Read vCard"), error)
                }
            }
        case .failure(let error):
            model.error = AppError(String(localized: "Couldn’t Import Contacts"), error)
        }
    }

    private func performImport(_ pending: PendingImport) async {
        _ = await model.importVCards(at: pending.urls,
                                     containerID: model.targetContainerID(for: browser.sidebarSelection),
                                     groupID: browser.currentGroupID)
    }
}

private struct ErrorAlert: ViewModifier {
    @Environment(ContactsModel.self) private var model

    func body(content: Content) -> some View {
        content.alert(model.error?.title ?? "", isPresented: Binding(
            get: { model.error != nil }, set: { if !$0 { model.error = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(model.error?.message ?? "")
        }
    }
}

private struct GroupPromptActions: View {
    @Bindable var browser: BrowserState
    @Environment(ContactsModel.self) private var model

    var body: some View {
        TextField("Group Name", text: Binding(
            get: { browser.groupPrompt?.name ?? "" },
            set: { browser.groupPrompt?.name = $0 }))
        Button("Cancel", role: .cancel) {}
        Button(browser.groupPrompt?.groupID == nil ? "Create" : "Rename") {
            guard let prompt = browser.groupPrompt, let name = prompt.name.trimmed.nilIfBlank else { return }
            Task {
                if let id = prompt.groupID {
                    await model.renameGroup(id, to: name)
                } else if let id = await model.createGroup(named: name, containerID: prompt.containerID) {
                    browser.sidebarSelection = .group(id)
                }
            }
        }
    }
}

/// Shows the selected contact, a multi-selection summary, or an empty state.
private struct DetailColumn: View {
    var browser: BrowserState
    @Environment(ContactsModel.self) private var model

    var body: some View {
        if let id = browser.selectedContactID {
            ContactDetailView(contactID: id, browser: browser)
                .id(id)
        } else if browser.selection.count > 1 {
            MultipleSelectionView(browser: browser)
        } else {
            ContentUnavailableView("No Contact Selected", systemImage: "person.crop.rectangle")
        }
    }
}

private struct MultipleSelectionView: View {
    var browser: BrowserState
    @Environment(ContactsModel.self) private var model

    var body: some View {
        let ids = orderedSelection
        ContentUnavailableView {
            Label("\(ids.count) Contacts Selected", systemImage: "person.2.crop.square.stack")
        } actions: {
            ShareLink(item: ContactsVCard(ids: ids, filename: String(localized: "\(ids.count) Contacts")),
                      preview: SharePreview("\(ids.count) Contacts")) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            GroupMembershipMenu(ids: Set(ids))
            Button(role: .destructive) {
                browser.confirmDelete(Set(ids), model: model)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var orderedSelection: [String] {
        model.contacts.map(\.id).filter(browser.selection.contains)
    }
}

/// "Add to Group" / "Remove from Group" menu for one or more contacts.
struct GroupMembershipMenu: View {
    var ids: Set<String>
    @Environment(ContactsModel.self) private var model

    var body: some View {
        if !model.groups.isEmpty {
            Menu {
                ForEach(model.containers) { container in
                    let groups = model.groups(in: container.id)
                    if !groups.isEmpty {
                        Section(model.containers.count > 1 ? container.name : "") {
                            ForEach(groups) { group in
                                let allMembers = ids.allSatisfy { model.groupIDs(containing: $0).contains(group.id) }
                                Toggle(group.name, isOn: Binding(
                                    get: { allMembers },
                                    set: { isMember in
                                        Task { await model.setMembership(ids, group: group.id, isMember: isMember) }
                                    }))
                            }
                        }
                    }
                }
            } label: {
                Label("Groups", systemImage: "folder")
            }
        }
    }
}
