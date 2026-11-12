//
//  ContactsApp.swift
//  Contacts
//
//  Created by Kevin on 12/11/26.
//

import SwiftUI

@main
struct ContactsApp: App {
    @State private var model = ContactsModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
        .commands {
            ContactsCommands(model: model)
        }
        #if os(macOS)
        .defaultSize(width: 980, height: 640)
        #endif
    }
}
