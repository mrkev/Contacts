import Contacts
import PhotosUI
import SwiftUI

/// Create/edit form. Built in SwiftUI rather than `CNContactViewController` so it works the
/// same on macOS, where ContactsUI has no editor.
struct ContactEditorView: View {
    var request: EditorRequest
    var onSave: (String?) -> Void

    @Environment(ContactsModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ContactDraft()
    @State private var original = ContactDraft()
    @State private var containerID: String?
    @State private var hasLoaded = false
    @State private var isSaving = false
    @State private var revealed: Set<OptionalField> = []
    @State private var photoItem: PhotosPickerItem?
    @State private var isConfirmingDiscard = false

    private var isNew: Bool { request.contactID == nil }
    private var isDirty: Bool { draft != original }

    var body: some View {
        NavigationStack {
            Form {
                photoSection
                nameSection
                companySection
                LabeledEntriesSection(title: "Phone", kind: .phone, entries: $draft.phoneNumbers, newValue: "") { $value in
                    TextField("Phone", text: $value)
                        #if os(iOS)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                        #endif
                }
                LabeledEntriesSection(title: "Email", kind: .email, entries: $draft.emailAddresses, newValue: "") { $value in
                    TextField("Email", text: $value)
                        .textContentType(.emailAddress)
                        #if os(iOS)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                }
                LabeledEntriesSection(title: "URL", kind: .url, entries: $draft.urlAddresses, newValue: "") { $value in
                    TextField("URL", text: $value)
                        .textContentType(.URL)
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                }
                LabeledEntriesSection(title: "Address", kind: .address, entries: $draft.postalAddresses,
                                      newValue: PostalAddressDraft()) { $address in
                    AddressFields(address: $address)
                }
                birthdaySection
                LabeledEntriesSection(title: "Related Name", kind: .relation, entries: $draft.relations, newValue: "") { $value in
                    TextField("Name", text: $value)
                        .textContentType(.name)
                }
                addFieldSection
                accountSection
            }
            .formStyle(.grouped)
            .navigationTitle(isNew ? "New Contact" : "Edit Contact")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if isDirty { isConfirmingDiscard = true } else { dismiss() }
                    }
                    .confirmationDialog("Discard changes?", isPresented: $isConfirmingDiscard) {
                        Button("Discard Changes", role: .destructive) { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Done", action: save)
                            .disabled(!draft.hasContent || (!isNew && !isDirty))
                    }
                }
            }
        }
        .interactiveDismissDisabled(isDirty)
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 560, idealHeight: 720)
        #endif
        .task { load() }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await loadPhoto(item) }
        }
    }

    // MARK: Sections

    private var photoSection: some View {
        Section {
            VStack(spacing: 10) {
                Group {
                    if let data = draft.imageData, let image = Image(imageData: data) {
                        image.resizable().scaledToFill()
                    } else {
                        Image(systemName: draft.isOrganization ? "building.2.crop.circle.fill" : "person.crop.circle.fill")
                            .resizable()
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 88, height: 88)
                .clipShape(.circle)

                HStack(spacing: 16) {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Text(draft.imageData == nil ? "Add Photo" : "Change Photo")
                    }
                    if draft.imageData != nil {
                        Button("Remove", role: .destructive) {
                            draft.imageData = nil
                            draft.imageChanged = true
                            photoItem = nil
                        }
                    }
                }
                .buttonStyle(.borderless)
            }
            .frame(maxWidth: .infinity)
        }
        .listRowBackground(Color.clear)
    }

    private var nameSection: some View {
        Section {
            optionalField(.prefix, "Prefix", text: $draft.namePrefix)
            TextField("First name", text: $draft.givenName)
                .textContentType(.givenName)
            optionalField(.phoneticGiven, "Phonetic first name", text: $draft.phoneticGivenName)
            optionalField(.middle, "Middle name", text: $draft.middleName)
            TextField("Last name", text: $draft.familyName)
                .textContentType(.familyName)
            optionalField(.phoneticFamily, "Phonetic last name", text: $draft.phoneticFamilyName)
            optionalField(.suffix, "Suffix", text: $draft.nameSuffix)
            optionalField(.nickname, "Nickname", text: $draft.nickname)
        }
    }

    private var companySection: some View {
        Section {
            TextField("Company", text: $draft.organizationName)
                .textContentType(.organizationName)
            optionalField(.jobTitle, "Job title", text: $draft.jobTitle)
            optionalField(.department, "Department", text: $draft.departmentName)
            Toggle("Show as Company", isOn: $draft.isOrganization)
                .disabled(draft.organizationName.nilIfBlank == nil && !draft.isOrganization)
        }
    }

    @ViewBuilder
    private var birthdaySection: some View {
        Section {
            if let birthday = Binding($draft.birthday) {
                HStack {
                    DatePicker("Birthday", selection: birthday.date, displayedComponents: .date)
                    RemoveButton { draft.birthday = nil }
                }
                Toggle("Include year", isOn: birthday.includesYear)
            } else {
                Button {
                    draft.birthday = BirthdayDraft()
                } label: {
                    Label("Add Birthday", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderless)
            }
        }
    }

    @ViewBuilder
    private var addFieldSection: some View {
        let hidden = OptionalField.allCases.filter { !isVisible($0) }
        if !hidden.isEmpty {
            Section {
                Menu {
                    ForEach(hidden) { field in
                        Button(field.title) { revealed.insert(field) }
                    }
                } label: {
                    Label("Add Field", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderless)
            }
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        if isNew, model.containers.count > 1 {
            Section {
                Picker("Account", selection: $containerID) {
                    ForEach(model.containers) { container in
                        Text(container.name).tag(Optional(container.id))
                    }
                }
            } footer: {
                Text("New contacts are saved to this account and sync to its other devices.")
            }
        }
    }

    // MARK: Optional name fields

    enum OptionalField: String, CaseIterable, Identifiable {
        case prefix, phoneticGiven, middle, phoneticFamily, suffix, nickname, jobTitle, department
        var id: Self { self }

        var title: LocalizedStringKey {
            switch self {
            case .prefix: "Prefix"
            case .phoneticGiven: "Phonetic First Name"
            case .middle: "Middle Name"
            case .phoneticFamily: "Phonetic Last Name"
            case .suffix: "Suffix"
            case .nickname: "Nickname"
            case .jobTitle: "Job Title"
            case .department: "Department"
            }
        }
    }

    private func value(of field: OptionalField) -> String {
        switch field {
        case .prefix: draft.namePrefix
        case .phoneticGiven: draft.phoneticGivenName
        case .middle: draft.middleName
        case .phoneticFamily: draft.phoneticFamilyName
        case .suffix: draft.nameSuffix
        case .nickname: draft.nickname
        case .jobTitle: draft.jobTitle
        case .department: draft.departmentName
        }
    }

    private func isVisible(_ field: OptionalField) -> Bool {
        revealed.contains(field) || value(of: field).nilIfBlank != nil
    }

    @ViewBuilder
    private func optionalField(_ field: OptionalField, _ title: LocalizedStringKey, text: Binding<String>) -> some View {
        if isVisible(field) {
            TextField(title, text: text)
        }
    }

    // MARK: Actions

    private func load() {
        guard !hasLoaded else { return }
        hasLoaded = true
        containerID = request.containerID ?? model.defaultContainerID
        guard let id = request.contactID else { return }
        do {
            let contact = try model.repository.contact(withID: id, keys: ContactDraft.requiredKeys)
            draft = ContactDraft(contact: contact)
            original = draft
        } catch {
            model.error = AppError(String(localized: "Couldn’t Open Contact"), error)
            dismiss()
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        let resized = await Task.detached { ImageDownscaler.jpegData(from: data) }.value
        draft.imageData = resized ?? data
        draft.imageChanged = true
    }

    private func save() {
        isSaving = true
        Task {
            let savedID = await model.save(draft, contactID: request.contactID, containerID: containerID,
                                           groupID: request.groupID)
            isSaving = false
            if savedID != nil {
                onSave(savedID)
                dismiss()
            }
        }
    }
}

/// A section of label + value rows for one multi-value field, with add/remove.
private struct LabeledEntriesSection<Value: Hashable & Sendable, Field: View>: View {
    var title: LocalizedStringKey
    var kind: LabeledFieldKind
    @Binding var entries: [LabeledEntry<Value>]
    var newValue: Value
    @ViewBuilder var field: (Binding<Value>) -> Field

    var body: some View {
        Section {
            ForEach($entries) { $entry in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    LabelPicker(kind: kind, label: $entry.label)
                        .frame(width: 96, alignment: .leading)
                    field($entry.value)
                    RemoveButton { entries.removeAll { $0.id == entry.id } }
                }
            }
            .onDelete { entries.remove(atOffsets: $0) }
            .onMove { entries.move(fromOffsets: $0, toOffset: $1) }

            Button {
                entries.append(LabeledEntry(label: kind.defaultLabel(excluding: entries.map(\.label)), value: newValue))
            } label: {
                Label {
                    Text("Add \(Text(title))")
                } icon: {
                    Image(systemName: "plus.circle.fill").foregroundStyle(.green)
                }
            }
            .buttonStyle(.borderless)
        }
    }
}

private struct LabelPicker: View {
    var kind: LabeledFieldKind
    @Binding var label: String?
    @State private var isEnteringCustom = false
    @State private var customText = ""

    var body: some View {
        Menu {
            ForEach(kind.suggestedLabels, id: \.self) { option in
                Button {
                    label = option
                } label: {
                    if option == label {
                        Label(ContactLabel.localized(option), systemImage: "checkmark")
                    } else {
                        Text(ContactLabel.localized(option))
                    }
                }
            }
            Divider()
            Button("Custom Label…") {
                customText = ""
                isEnteringCustom = true
            }
        } label: {
            HStack(spacing: 2) {
                Text(ContactLabel.localized(label))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
            }
            .font(.subheadline)
            .foregroundStyle(.tint)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .alert("Custom Label", isPresented: $isEnteringCustom) {
            TextField("Label", text: $customText)
            Button("Cancel", role: .cancel) {}
            Button("OK") {
                if let custom = customText.trimmed.nilIfBlank { label = custom }
            }
        }
    }
}

private struct AddressFields: View {
    @Binding var address: PostalAddressDraft

    var body: some View {
        VStack(spacing: 6) {
            TextField("Street", text: $address.street, axis: .vertical)
                .textContentType(.fullStreetAddress)
            HStack {
                TextField("City", text: $address.city)
                    .textContentType(.addressCity)
                TextField("State", text: $address.state)
                    .textContentType(.addressState)
            }
            HStack {
                TextField("ZIP", text: $address.postalCode)
                    .textContentType(.postalCode)
                TextField("Country", text: $address.country)
                    .textContentType(.countryName)
            }
        }
    }
}

private struct RemoveButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "minus.circle.fill")
                .foregroundStyle(.red)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Remove")
    }
}
