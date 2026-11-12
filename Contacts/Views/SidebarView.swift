import SwiftUI

struct SidebarView: View {
    @Bindable var browser: BrowserState
    @Environment(ContactsModel.self) private var model

    var body: some View {
        List(selection: $browser.sidebarSelection) {
            Section {
                row(.allContacts, icon: "person.2", count: model.contacts.count)
                row(.birthdays, icon: "gift", count: nil)
            }

            ForEach(model.containers) { container in
                Section(container.name) {
                    if model.containers.count > 1 {
                        row(.container(container.id), title: String(localized: "All \(container.name)"),
                            icon: "tray.full", count: nil)
                    }
                    ForEach(model.groups(in: container.id)) { group in
                        row(.group(group.id), icon: "folder", count: nil)
                            .contextMenu {
                                Button("Rename…", systemImage: "pencil") {
                                    browser.groupPrompt = GroupPrompt(groupID: group.id, containerID: group.containerID,
                                                                      name: group.name)
                                }
                                Button("Delete Group", systemImage: "trash", role: .destructive) {
                                    Task { await model.deleteGroup(group.id) }
                                }
                            }
                    }
                }
            }
        }
        .navigationTitle("Lists")
        #if os(macOS)
        .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        #endif
        .toolbar {
            ToolbarItem {
                Button("New Group", systemImage: "folder.badge.plus") { browser.newGroup(in: model) }
            }
        }
        .refreshable { await model.reload() }
    }

    private func row(_ item: SidebarItem, title: String? = nil, icon: String, count: Int?) -> some View {
        NavigationLink(value: item) {
            Label(title ?? model.title(for: item), systemImage: icon)
                .badge(count ?? 0)
        }
    }
}
