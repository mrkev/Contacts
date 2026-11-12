import SwiftUI

/// Gates the app on Contacts authorization.
struct RootView: View {
    @Environment(ContactsModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if model.access.canRead {
                BrowserView()
            } else {
                AccessView()
            }
        }
        .onAppear { model.refreshAccess() }
        // The user may change access in Settings while we're in the background.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refreshAccess() }
        }
    }
}

struct AccessView: View {
    @Environment(ContactsModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        ContentUnavailableView {
            Label("Contacts", systemImage: "person.crop.circle")
        } description: {
            switch model.access {
            case .notDetermined:
                Text("See, edit, and organize the people in your address book, including contacts synced from iCloud, Google, and Exchange.")
            case .restricted:
                Text("Access to contacts is restricted on this device, possibly by Screen Time or a device management profile.")
            default:
                Text("Contacts access is turned off. You can turn it on in Settings.")
            }
        } actions: {
            switch model.access {
            case .notDetermined:
                Button("Continue") { Task { await model.requestAccess() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            case .denied:
                Button("Open Settings") { openURL(Self.settingsURL) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            default:
                EmptyView()
            }
        }
    }

    private static var settingsURL: URL {
        #if os(macOS)
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts")!
        #else
        URL(string: UIApplication.openSettingsURLString)!
        #endif
    }
}
