import SwiftUI

/// Per-day summary used for the calendar dots (completion + countdown events).
struct DayFlag {
    let total: Int
    let done: Int
    let events: Int
}

struct CalendarView: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var viewYear: Int
    @State private var viewMonth: Int      // 1...12
    @State private var selectedDate: String
    @State private var dayFlags: [String: DayFlag] = [:]
    @State private var dayTasks: [KidTask] = []
    @State private var busy = false
    @State private var minutesTask: KidTask?
    @State private var refreshKey = 0

    private let weekdayNames = ["S", "M", "T", "W", "T", "F", "S"]
    private var api: APIClient { APIClient(settings: settings) }

    init() {
        let now = Date()
        _viewYear = State(initialValue: Calendar.current.component(.year, from: now))
        _viewMonth = State(initialValue: Calendar.current.component(.month, from: now))
        _selectedDate = State(initialValue: Self.iso(now))
    }

    static func iso(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    var body: some View {
        VStack(spacing: 12) {
            header
            monthGrid
            Divider()
            dayList
        }
        .padding(16)
        .navigationTitle("Calendar")
        .task(id: refreshKey) { await loadAll() }
        .onChange(of: settings.host) { _, _ in refreshKey += 1 }
        .onChange(of: settings.port) { _, _ in refreshKey += 1 }
        .onChange(of: settings.pin) { _, _ in refreshKey += 1 }
        .onChange(of: settings.role) { _, _ in refreshKey += 1 }
        .sheet(item: $minutesTask) { task in
            MinutesSheet(task: task) { minutes in
                Task {
                    busy = true
                    do { try await api.toggle(id: task.id, minutes: minutes); await loadAll() }
                    catch let e { await showError(e) }
                    busy = false
                }
            }
        }
    }

    // MARK: - header / month navigation

    private var header: some View {
        HStack {
            Button { stepMonth(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.bordered)
            Spacer()
            Text(monthLabel).font(.title3.bold())
            Spacer()
            Button { stepMonth(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.bordered)
            Button("Today") { goToday() }.buttonStyle(.bordered)
        }
    }

    private var monthLabel: String {
        dateFor(viewYear, viewMonth, 1).formatted(.dateTime.month(.wide).year())
    }

    private func stepMonth(_ delta: Int) {
        var comp = DateComponents()
        comp.year = viewYear
        comp.month = viewMonth + delta
        comp.day = 1
        if let d = Calendar.current.date(from: comp) {
            viewYear = Calendar.current.component(.year, from: d)
            viewMonth = Calendar.current.component(.month, from: d)
        }
        Task { await loadFlags(); await loadDay() }
    }

    private func goToday() {
        let now = Date()
        viewYear = Calendar.current.component(.year, from: now)
        viewMonth = Calendar.current.component(.month, from: now)
        selectedDate = Self.iso(now)
        Task { await loadAll() }
    }

    // MARK: - month grid

    private var monthGrid: some View {
        let first = dateFor(viewYear, viewMonth, 1)
        let firstWeekday = Calendar.current.component(.weekday, from: first) // 1=Sun ... 7=Sat
        let days = Calendar.current.range(of: .day, in: .month, for: first)?.count ?? 30
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
        return LazyVGrid(columns: columns, spacing: 6) {
            ForEach(weekdayNames, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            ForEach(0..<(firstWeekday - 1), id: \.self) { _ in Color.clear.frame(height: 38) }
            ForEach(1...days, id: \.self) { day in dayCell(day: day) }
        }
    }

    private func dayCell(day: Int) -> some View {
        let iso = String(format: "%04d-%02d-%02d", viewYear, viewMonth, day)
        let isToday = iso == Self.iso(Date())
        let isSelected = iso == selectedDate
        let fl = dayFlags[iso]
        return Button {
            selectedDate = iso
            Task { await loadDay() }
        } label: {
            VStack(spacing: 2) {
                Text("\(day)").font(.callout)
                HStack(spacing: 2) {
                    if let fl, fl.total > 0 {
                        Circle().fill(fl.done == fl.total ? Color.green : Color.orange).frame(width: 5, height: 5)
                    }
                    if let fl, fl.events > 0 {
                        Circle().fill(Color.pink).frame(width: 5, height: 5)
                    }
                }
                .frame(height: 6)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(isSelected ? Color.accentColor.opacity(0.22) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(isToday ? Color.accentColor : Color.clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .help(iso)
    }

    // MARK: - selected day's list

    private var dayList: some View {
        Group {
            if dayTasks.isEmpty {
                ContentUnavailableView("No tasks for this day",
                    systemImage: "checkmark.circle",
                    description: Text("Select a day to see its tasks."))
            } else {
                List(dayTasks) { task in taskRow(task) }
            }
        }
    }

    private func taskRow(_ task: KidTask) -> some View {
        HStack(spacing: 12) {
            Text(task.emoji.isEmpty ? "📝" : task.emoji).font(.system(size: 24))
            HStack(spacing: 4) {
                Text(task.title)
                    .strikethrough(task.done)
                    .foregroundStyle(task.done ? .secondary : .primary)
                if task.isParentOnly {
                    Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                        .help("Parent only — hidden from the kid")
                }
            }
            RepeatBadge(task: task)
            Spacer()
            if let c = task.countdownText { Text(c).font(.caption.bold()).foregroundStyle(.pink) }
            if settings.canModify(task) {
                Button { delete(task) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
            Button(task.done ? "Undo" : "Done") { complete(task) }
                .buttonStyle(.borderedProminent)
                .tint(task.done ? .gray : .green)
        }
        .padding(.vertical, 5)
    }

    private func complete(_ task: KidTask) {
        if task.done {
            Task { busy = true; do { try await api.toggle(id: task.id, minutes: nil); await loadAll() } catch let e { await showError(e) }; busy = false }
        } else {
            minutesTask = task
        }
    }

    private func delete(_ task: KidTask) {
        Task { busy = true; do { try await api.delete(id: task.id); await loadAll() } catch let e { await showError(e) }; busy = false }
    }

    @MainActor
    private func showError(_ e: Error) {
        // simple in-place feedback: rely on reload retry; ignore transient errors silently
    }

    // MARK: - data

    private func loadAll() async {
        await loadFlags()
        await loadDay()
    }

    private func loadFlags() async {
        let first = dateFor(viewYear, viewMonth, 1)
        let days = Calendar.current.range(of: .day, in: .month, for: first)?.count ?? 30
        let dates = (1...days).map { String(format: "%04d-%02d-%02d", viewYear, viewMonth, $0) }
        var newFlags: [String: DayFlag] = [:]
        for iso in dates {
            if let all = try? await api.tasks(type: nil, date: iso) {
                let todo = all.filter { !$0.countdownEnabled }
                let done = todo.filter { $0.done }.count
                let events = all.filter { $0.countdownEnabled && $0.targetDate == iso }.count
                newFlags[iso] = DayFlag(total: todo.count, done: done, events: events)
            }
        }
        dayFlags = newFlags
    }

    private func loadDay() async {
        do {
            async let todo = api.tasks(type: "todo", date: selectedDate)
            async let cnt = api.tasks(type: "countdown", date: selectedDate)
            let (t, c) = try await (todo, cnt)
            let events = c.filter { $0.targetDate == selectedDate }
            dayTasks = t + events
        } catch {
            // leave the list as-is on transient errors
        }
    }

    private func dateFor(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d
        return Calendar.current.date(from: comps) ?? Date()
    }
}
