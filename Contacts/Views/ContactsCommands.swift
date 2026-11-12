import SwiftUI

/// Menu bar commands on macOS and keyboard shortcuts on iPad.
struct ContactsCommands: Commands {
    var model: ContactsModel
    @FocusedValue(\.browser) private var browser

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Group {
                Button("New Contact") { browser?.newContact(in: model) }
                    .keyboardShortcut("n")
                Button("New Group") { browser?.newGroup(in: model) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            .disabled(browser == nil)
        }

        CommandGroup(replacing: .importExport) {
            Button("Import vCard…") { browser?.isImporting = true }
                .keyboardShortcut("o")
            Button("Export Selected as vCard…") {
                guard let browser else { return }
                let ids = model.contacts.map(\.id).filter(browser.selection.contains)
                Task { await browser.exportVCards(ids, model: model) }
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(browser?.selection.isEmpty ?? true)
        }

        CommandMenu("Card") {
            Button("Edit Card") {
                if let id = browser?.selectedContactID { browser?.edit(id) }
            }
            .keyboardShortcut("l")
            .disabled(browser?.selectedContactID == nil)

            Button("Delete Card…") {
                if let browser { browser.confirmDelete(browser.selection, model: model) }
            }
            .keyboardShortcut(.delete)
            .disabled(browser?.selection.isEmpty ?? true)

            Divider()

            Button("Show All Contacts") { browser?.sidebarSelection = .allContacts }
                .keyboardShortcut("1")
            Button("Show Birthdays") { browser?.sidebarSelection = .birthdays }
                .keyboardShortcut("2")

            Divider()

            Button("Reload") { Task { await model.reload() } }
                .keyboardShortcut("r")
        }
    }
}
