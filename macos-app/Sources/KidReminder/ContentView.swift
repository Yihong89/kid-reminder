import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case today = "Today"
    case calendar = "Calendar"
    case countdown = "Countdown"
    case stickers = "Stickers"
    case dictation = "听写"
    case english = "英语错题"
    case settings = "Settings"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .today: return "checklist"
        case .calendar: return "calendar"
        case .countdown: return "timer"
        case .stickers: return "star.circle.fill"
        case .dictation: return "speaker.wave.2.fill"
        case .english: return "text.book.closed.fill"
        case .settings: return "gearshape"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var selection: SidebarItem = .today
    @StateObject private var updater = AppUpdater()

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
            case .stickers: StickersView()
            case .dictation: DictationView()
            case .english: EnglishPracticeView()
            case .settings: SettingsView()
            }
        }
        .task { await updater.check() }
    }
}
