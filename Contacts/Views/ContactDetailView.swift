import Contacts
import SwiftUI

struct ContactDetailView: View {
    var contactID: String
    var browser: BrowserState
    @Environment(ContactsModel.self) private var model
    @State private var contact: CNContact?
    @State private var loadFailed = false

    var body: some View {
        Group {
            if let contact {
                ContactCard(contact: contact, isMe: contactID == model.meContactID)
            } else if loadFailed {
                ContentUnavailableView("Contact Unavailable", systemImage: "person.crop.circle.badge.exclamationmark",
                                       description: Text("This contact may have been deleted."))
            } else {
                ProgressView()
            }
        }
        // Refetch whenever the store reloads so edits made anywhere show up.
        .task(id: model.revision) {
            do {
                contact = try model.contact(contactID)
                loadFailed = false
            } catch {
                contact = nil
                loadFailed = true
            }
        }
        .toolbar {
            if contact != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { browser.edit(contactID) }
                        .keyboardShortcut("l", modifiers: .command)
                }
                ToolbarItem {
                    ShareLink(item: ContactsVCard(ids: [contactID], filename: displayName),
                              preview: SharePreview(displayName))
                }
                ToolbarItem {
                    Menu("More", systemImage: "ellipsis.circle") {
                        GroupMembershipMenu(ids: [contactID])
                        Button("Export vCard…", systemImage: "square.and.arrow.down") {
                            Task { await browser.exportVCards([contactID], model: model) }
                        }
                        Divider()
                        Button("Delete Contact", systemImage: "trash", role: .destructive) {
                            browser.confirmDelete([contactID], model: model)
                        }
                    }
                }
            }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var displayName: String {
        model.summary(contactID)?.displayName ?? String(localized: "Contact")
    }
}

/// Read-only presentation of a full contact.
struct ContactCard: View {
    var contact: CNContact
    var isMe = false
    @Environment(ContactsModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            Section {
                header
                QuickActionsRow(contact: contact)
                    .padding(.bottom, 4)
            }
            .listRowBackground(Color.clear)
            #if os(iOS)
            .listRowInsets(EdgeInsets())
            #endif

            fields(contact.phoneNumbers, value: { $0.stringValue }, url: { ContactActionURL.call($0.stringValue) })
            fields(contact.emailAddresses, value: { $0 as String }, url: { ContactActionURL.email($0 as String) })
            fields(contact.urlAddresses, value: { $0 as String }, url: { ContactActionURL.web($0 as String) })
            fields(contact.postalAddresses,
                   value: { CNPostalAddressFormatter.string(from: $0, style: .mailingAddress) },
                   url: { ContactActionURL.maps(CNPostalAddressFormatter.string(from: $0, style: .mailingAddress)) })

            datesSection
            fields(contact.contactRelations, value: { $0.name }, url: { _ in nil })
            fields(contact.socialProfiles,
                   value: { profile in
                       [profile.service.nilIfBlank, profile.username.nilIfBlank].compactMap { $0 }.joined(separator: ": ")
                   },
                   url: { profile in profile.urlString.nilIfBlank.flatMap(ContactActionURL.web) },
                   label: { $0.label ?? $0.value.service })
            fields(contact.instantMessageAddresses,
                   value: { [$0.service.nilIfBlank, $0.username.nilIfBlank].compactMap { $0 }.joined(separator: ": ") },
                   url: { _ in nil },
                   label: { $0.label ?? $0.value.service })
            groupsSection
        }
        .formStyle(.grouped)
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 8) {
            AvatarView(contactID: contact.identifier,
                       initials: ContactsRepository.initials(given: contact.givenName, family: contact.familyName,
                                                             fallback: name),
                       isOrganization: contact.contactType == .organization,
                       hasImage: contact.imageDataAvailable,
                       size: 96,
                       imageData: contact.imageDataAvailable ? contact.imageData : nil)
            Text(name)
                .font(.title.weight(.semibold))
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            if let nickname = contact.nickname.nilIfBlank {
                Text("“\(nickname)”").foregroundStyle(.secondary)
            }
            if let subtitle {
                Text(subtitle)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if isMe {
                Text("My Card")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(.quaternary, in: .capsule)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
    }

    private var name: String {
        if contact.contactType == .organization, let organization = contact.organizationName.nilIfBlank {
            return organization
        }
        return CNContactFormatter.string(from: contact, style: .fullName)?.nilIfBlank
            ?? contact.organizationName.nilIfBlank
            ?? String(localized: "No Name")
    }

    private var subtitle: String? {
        let job = [contact.jobTitle.nilIfBlank, contact.departmentName.nilIfBlank].compactMap { $0 }.joined(separator: " — ")
        let organization = contact.contactType == .organization ? nil : contact.organizationName.nilIfBlank
        return [job.nilIfBlank, organization].compactMap { $0 }.joined(separator: "\n").nilIfBlank
    }

    // MARK: Field sections

    @ViewBuilder
    private func fields<V>(
        _ values: [CNLabeledValue<V>],
        value: @escaping (V) -> String,
        url: @escaping (V) -> URL?,
        label: ((CNLabeledValue<V>) -> String?)? = nil
    ) -> some View {
        if !values.isEmpty {
            Section {
                ForEach(values, id: \.identifier) { labeled in
                    FieldRow(label: label?(labeled) ?? ContactLabel.localized(labeled.label),
                             value: value(labeled.value),
                             url: url(labeled.value))
                }
            }
        }
    }

    @ViewBuilder
    private var datesSection: some View {
        let birthday = contact.birthday.flatMap(BirthdayFormatting.string(for:))
        if birthday != nil || !contact.dates.isEmpty {
            Section {
                if let birthday, let components = contact.birthday {
                    FieldRow(label: String(localized: "birthday"), value: birthday, url: nil,
                             detail: Self.birthdayDetail(components))
                }
                ForEach(contact.dates, id: \.identifier) { date in
                    if let string = BirthdayFormatting.string(for: date.value as DateComponents) {
                        FieldRow(label: ContactLabel.localized(date.label), value: string, url: nil)
                    }
                }
            }
        }
    }

    private static func birthdayDetail(_ components: DateComponents) -> String? {
        guard let next = UpcomingBirthday.nextOccurrence(of: components, after: Calendar.current.startOfDay(for: .now),
                                                         calendar: .current) else { return nil }
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: .now), to: next).day ?? 0
        guard days <= 30 else { return nil }
        return BirthdayFormatting.relativeDescription(daysAway: days)
    }

    @ViewBuilder
    private var groupsSection: some View {
        let groups = model.groupIDs(containing: contact.identifier).compactMap(model.group)
        if !groups.isEmpty {
            Section("Groups") {
                Text(groups.map(\.name).formatted(.list(type: .and)))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A labeled value that opens a URL when tapped and can be copied.
private struct FieldRow: View {
    var label: String
    var value: String
    var url: URL?
    var detail: String?
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            if let url { openURL(url) }
        } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(value)
                        .foregroundStyle(url == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
                        .multilineTextAlignment(.leading)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.tint)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(url == nil)
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") { Pasteboard.copy(value) }
            if let url {
                Button("Open", systemImage: "arrow.up.forward.app") { openURL(url) }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Message / Call / Video / Mail buttons. With several numbers or addresses, each becomes a menu.
private struct QuickActionsRow: View {
    var contact: CNContact

    private var phones: [CNLabeledValue<CNPhoneNumber>] { contact.phoneNumbers }
    private var emails: [CNLabeledValue<NSString>] { contact.emailAddresses }

    var body: some View {
        HStack(spacing: 10) {
            QuickActionButton(title: "message", systemImage: "message.fill",
                              targets: phones.map { (ContactLabel.localized($0.label), $0.value.stringValue) }
                                + emails.map { (ContactLabel.localized($0.label), $0.value as String) },
                              url: ContactActionURL.message)
            QuickActionButton(title: "call", systemImage: "phone.fill",
                              targets: phones.map { (ContactLabel.localized($0.label), $0.value.stringValue) },
                              url: ContactActionURL.call)
            QuickActionButton(title: "video", systemImage: "video.fill",
                              targets: phones.map { (ContactLabel.localized($0.label), $0.value.stringValue) }
                                + emails.map { (ContactLabel.localized($0.label), $0.value as String) },
                              url: ContactActionURL.faceTime)
            QuickActionButton(title: "mail", systemImage: "envelope.fill",
                              targets: emails.map { (ContactLabel.localized($0.label), $0.value as String) },
                              url: ContactActionURL.email)
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity)
    }
}

private struct QuickActionButton: View {
    var title: LocalizedStringKey
    var systemImage: String
    var targets: [(label: String, value: String)]
    var url: (String) -> URL?
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            if targets.count > 1 {
                Menu {
                    ForEach(Array(targets.enumerated()), id: \.offset) { _, target in
                        Button("\(target.label): \(target.value)") { open(target.value) }
                    }
                } label: {
                    content
                }
                .menuIndicator(.hidden)
            } else {
                Button {
                    if let value = targets.first?.value { open(value) }
                } label: {
                    content
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(targets.isEmpty)
        .opacity(targets.isEmpty ? 0.4 : 1)
    }

    private var content: some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.title3)
            Text(title)
                .font(.caption2)
        }
        .foregroundStyle(.tint)
        .frame(maxWidth: .infinity, minHeight: 52)
        .background(.fill.tertiary, in: .rect(cornerRadius: 10))
        .contentShape(.rect)
    }

    private func open(_ value: String) {
        if let url = url(value) { openURL(url) }
    }
}
