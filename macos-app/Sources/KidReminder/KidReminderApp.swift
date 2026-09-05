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
        // zoom button to give it regardless of how its frame is sized.
        //
        // .windowResizability(.contentMinSize), not .defaultSize(width:height:) —
        // the first attempt at this used .defaultSize and crashed on open
        // (_postWindowNeedsUpdateConstraints / _informContainerThatSubviewsNeed-
        // UpdateConstraints recursion). .contentMinSize is what the main
        // WindowGroup above already uses without incident: it takes its floor
        // from the content's own .frame(minWidth:minHeight:) in
        // ScienceRunnerView rather than asserting a separate Scene-level size,
        // which was the suspected source of the two sizing directives fighting
        // during the very first layout pass of a brand-new window.
        WindowGroup(id: "science-runner", for: ScienceSource.self) { $source in
            if let source {
                NavigationStack {
                    ScienceRunnerView(source: source)
                }
                .environmentObject(settings)
            }
        }
        .windowResizability(.contentMinSize)
    }
}
