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

        // 科学 practice opens as its own top-level window rather than a sheet
        // from SciencePracticeView, specifically so it gets a real title bar —
        // a sheet has no titlebar controls at all, so there is no maximize/
        // zoom button to give it regardless of how its frame is sized. This is
        // the fix for exactly that complaint.
        WindowGroup(id: "science-runner", for: ScienceSource.self) { $source in
            if let source {
                NavigationStack {
                    ScienceRunnerView(source: source)
                }
                .environmentObject(settings)
            }
        }
        .defaultSize(width: 1000, height: 760)
    }
}
