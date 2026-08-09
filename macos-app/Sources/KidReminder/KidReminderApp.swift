import SwiftUI

@main
struct KidReminderApp: App {
    @StateObject private var settings = SettingsStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .frame(minWidth: 460, minHeight: 620)
        }
        .windowResizability(.contentMinSize)
    }
}
