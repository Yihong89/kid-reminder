import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case today = "Today"
    case calendar = "Calendar"
    case countdown = "Countdown"
    case settings = "Settings"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .today: return "checklist"
        case .calendar: return "calendar"
        case .countdown: return "timer"
        case .settings: return "gearshape"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var selection: SidebarItem = .today

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.rawValue, systemImage: item.icon).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 130, ideal: 150, max: 180)
        } detail: {
            switch selection {
            case .today: TodayView()
            case .calendar: CalendarView()
            case .countdown: CountdownView()
            case .settings: SettingsView()
            }
        }
    }
}
