import SwiftUI

#if os(iOS)
import ContactsUI
#endif

struct ContactListView: View {
    @Bindable var browser: BrowserState
    @Environment(ContactsModel.self) private var model
    #if os(iOS)
    @State private var isShowingAccessPicker = false
    #endif

    private var sidebarItem: SidebarItem { browser.sidebarSelection ?? .allContacts }

    var body: some View {
        let contacts = model.contacts(in: sidebarItem, matching: browser.searchText)
        List(selection: $browser.selection) {
            #if os(iOS)
            limitedAccessContent
            #endif
            if sidebarItem == .birthdays {
                birthdayRows(for: contacts)
            } else {
                sectionedRows(for: contacts)
            }
        }
        #if os(iOS)
        .listSectionIndexVisibility(.visible)
        #endif
        .overlay { emptyState(isEmpty: contacts.isEmpty) }
        .navigationTitle(model.title(for: sidebarItem))
        #if os(macOS)
        .navigationSubtitle(model.hasLoaded ? String(localized: "\(contacts.count) contacts") : "")
        .navigationSplitViewColumnWidth(min: 220, ideal: 280)
        #endif
        .searchable(text: $browser.searchText, prompt: "Name, phone, email, company")
        .contextMenu(forSelectionType: String.self) { ids in
            selectionMenu(for: ids)
        } primaryAction: { ids in
            if ids.count == 1, let id = ids.first { browser.edit(id) }
        }
        #if os(macOS)
        .onDeleteCommand { browser.confirmDelete(browser.selection, model: model) }
        #endif
        .toolbar { toolbarContent }
        .refreshable { await model.reload() }
        #if os(iOS)
        .contactAccessPicker(isPresented: $isShowingAccessPicker) { _ in
            Task { await model.reload() }
        }
        #endif
    }

    // MARK: Rows

    @ViewBuilder
    private func sectionedRows(for contacts: [ContactSummary]) -> some View {
        ForEach(ContactSection.sections(for: contacts)) { section in
            Section(section.title) {
                ForEach(section.contacts) { contact in
                    row(contact)
                }
            }
            #if os(iOS)
            .sectionIndexLabel(section.title)
            #endif
        }
    }

    @ViewBuilder
    private func birthdayRows(for contacts: [ContactSummary]) -> some View {
        let upcoming = UpcomingBirthday.upcoming(from: contacts)
        let soon = upcoming.filter { $0.daysAway <= 30 }
        let later = upcoming.filter { $0.daysAway > 30 }
        if !soon.isEmpty {
            Section("Next 30 Days") {
                ForEach(soon) { birthdayRow($0) }
            }
        }
        if !later.isEmpty {
            Section("Later") {
                ForEach(later) { birthdayRow($0) }
            }
        }
    }

    private func row(_ contact: ContactSummary) -> some View {
        NavigationLink(value: contact.id) {
            ContactRow(contact: contact, isMe: contact.id == model.meContactID)
        }
        .draggable(ContactsVCard(ids: [contact.id], filename: contact.displayName)) {
            Label(contact.displayName, systemImage: "person.crop.rectangle")
        }
    }

    private func birthdayRow(_ birthday: UpcomingBirthday) -> some View {
        NavigationLink(value: birthday.contact.id) {
            HStack(spacing: 10) {
                AvatarView(birthday.contact, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(birthday.contact.displayName)
                    Group {
                        if let age = birthday.turningAge {
                            Text("\(birthday.nextDate, format: .dateTime.month(.abbreviated).day()) · turns \(age)")
                        } else {
                            Text(birthday.nextDate, format: .dateTime.month(.abbreviated).day())
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Text(BirthdayFormatting.relativeDescription(daysAway: birthday.daysAway))
                    .font(.caption.weight(birthday.daysAway <= 7 ? .semibold : .regular))
                    .foregroundStyle(birthday.daysAway <= 7 ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
        }
    }

    // MARK: Empty & limited states

    @ViewBuilder
    private func emptyState(isEmpty: Bool) -> some View {
        if isEmpty, model.hasLoaded {
            if !browser.searchText.trimmed.isEmpty {
                ContentUnavailableView.search(text: browser.searchText)
            } else if sidebarItem == .birthdays {
                ContentUnavailableView("No Birthdays", systemImage: "gift",
                                       description: Text("Birthdays you add to contacts appear here."))
            } else if case .group = sidebarItem {
                ContentUnavailableView("No Contacts in Group", systemImage: "folder",
                                       description: Text("Use “Groups” on a contact to add it here."))
            } else {
                ContentUnavailableView {
                    Label("No Contacts", systemImage: "person.crop.circle")
                } actions: {
                    Button("New Contact") { browser.newContact(in: model) }
                }
            }
        } else if isEmpty, model.isLoading {
            ProgressView()
        }
    }

    #if os(iOS)
    /// With limited access, search can surface contacts the app can't see yet; the system
    /// `ContactAccessButton` lets the user grant them one at a time.
    @ViewBuilder
    private var limitedAccessContent: some View {
        if model.access == .limited {
            if let query = browser.searchText.trimmed.nilIfBlank {
                Section {
                    ContactAccessButton(queryString: query) { _ in
                        Task { await model.reload() }
                    }
                }
            } else {
                Section {
                    Button {
                        isShowingAccessPicker = true
                    } label: {
                        Label("Choose which contacts this app can see", systemImage: "person.crop.circle.badge.checkmark")
                    }
                } footer: {
                    Text("You’ve shared some of your contacts with this app.")
                }
            }
        }
    }
    #endif

    // MARK: Menus & toolbar

    @ViewBuilder
    private func selectionMenu(for ids: Set<String>) -> some View {
        if ids.count == 1, let id = ids.first {
            Button("Edit", systemImage: "pencil") { browser.edit(id) }
        }
        if !ids.isEmpty {
            let ordered = model.contacts.map(\.id).filter(ids.contains)
            ShareLink(item: ContactsVCard(ids: ordered, filename: shareName(for: ordered)),
                      preview: SharePreview(shareName(for: ordered))) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            Button("Export vCard…", systemImage: "square.and.arrow.down") {
                Task { await browser.exportVCards(ordered, model: model) }
            }
            GroupMembershipMenu(ids: ids)
            if let groupID = browser.currentGroupID {
                Button("Remove from Group", systemImage: "folder.badge.minus") {
                    Task { await model.setMembership(ids, group: groupID, isMember: false) }
                }
            }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) {
                browser.confirmDelete(ids, model: model)
            }
        }
    }

    private func shareName(for ids: [String]) -> String {
        ids.count == 1 ? model.summary(ids[0])?.displayName ?? "Contact" : String(localized: "\(ids.count) Contacts")
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button("New Contact", systemImage: "plus") { browser.newContact(in: model) }
        }
        ToolbarItem(placement: .secondaryAction) {
            Button("Import vCard…", systemImage: "square.and.arrow.down.on.square") { browser.isImporting = true }
        }
        ToolbarItem(placement: .secondaryAction) {
            Button("Export All…", systemImage: "square.and.arrow.up.on.square") {
                let ids = model.contacts(in: sidebarItem).map(\.id)
                Task { await browser.exportVCards(ids, model: model) }
            }
            .disabled(model.contacts(in: sidebarItem).isEmpty)
        }
        #if os(iOS)
        ToolbarItem(placement: .topBarLeading) {
            EditButton()
        }
        #endif
    }
}

struct ContactRow: View {
    var contact: ContactSummary
    var isMe = false

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(contact, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(contact.displayName)
                        .lineLimit(1)
                    if isMe {
                        Text("me")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                if let subtitle = contact.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
