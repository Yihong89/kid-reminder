import SwiftUI

struct TodayView: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var tasks: [KidTask] = []
    @State private var upcoming: [KidTask] = []   // countdown events in the next 7 days
    @State private var error: String?
    @State private var busy = false
    @State private var refreshKey = 0
    @State private var showAdd = false
    @State private var minutesTask: KidTask?

    private var api: APIClient { APIClient(settings: settings) }

    var body: some View {
        Group {
            if settings.host.isEmpty || settings.pin.isEmpty {
                ContentUnavailableView("Not connected",
                    systemImage: "antenna.radiowaves.left.and.right.slash",
                    description: Text("Enter the server address and PIN in Settings."))
            } else if let error = error {
                ContentUnavailableView("Can't reach server",
                    systemImage: "wifi.exclamationmark",
                    description: Text(error))
                .toolbar { reloadToolbar }
            } else {
                List {
                    Section("Today") {
                        ForEach(tasks) { task in taskRow(task) }
                    }
                    if !upcoming.isEmpty {
                        Section("Next 7 days") {
                            ForEach(upcoming) { ev in eventRow(ev) }
                        }
                    }
                }
                .toolbar { reloadToolbar }
            }
        }
        .navigationTitle("Today")
        .sheet(isPresented: $showAdd) { AddTaskView(onSaved: { Task { await load() } }) }
        .sheet(item: $minutesTask) { task in
            MinutesSheet(task: task) { minutes in
                Task {
                    busy = true
                    do { try await api.toggle(id: task.id, minutes: minutes); await load() }
                    catch let e { error = errorMessage(e) }
                    busy = false
                }
            }
        }
        .task(id: refreshKey) { await load() }
        .onChange(of: settings.host) { _, _ in refreshKey += 1 }
        .onChange(of: settings.port) { _, _ in refreshKey += 1 }
        .onChange(of: settings.pin) { _, _ in refreshKey += 1 }
        .onChange(of: settings.role) { _, _ in refreshKey += 1 }
    }

    private var reloadToolbar: some ToolbarContent {
        ToolbarItemGroup {
            if busy { ProgressView().controlSize(.small) }
            Button { Task { await load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            Button { showAdd = true } label: { Label("Add", systemImage: "plus") }
        }
    }

    private func load() async {
        busy = true
        defer { busy = false }
        do {
            async let t = api.tasks(type: "todo")
            async let c = api.tasks(type: "countdown")
            let (todo, cnt) = try await (t, c)
            tasks = todo
            upcoming = cnt
                .filter { (0...7).contains($0.daysLeft ?? 999) }
                .sorted { ($0.daysLeft ?? 999) < ($1.daysLeft ?? 999) }
            error = nil
        } catch let e {
            error = errorMessage(e)
        }
    }

    private func taskRow(_ task: KidTask) -> some View {
        HStack(spacing: 12) {
            Text(task.emoji.isEmpty ? "📝" : task.emoji)
                .font(.system(size: 26))
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .strikethrough(task.done)
                    .foregroundStyle(task.done ? .secondary : .primary)
                if task.done && task.minutes > 0 {
                    Text("⏱ \(task.minutes)m").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if settings.canModify(task) {
                Button { delete(task) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Delete")
            }
            Button(task.done ? "Undo" : "Done") { complete(task) }
                .buttonStyle(.borderedProminent)
                .tint(task.done ? .gray : .green)
        }
        .padding(.vertical, 6)
    }

    /// Row for a countdown event in the "next 7 days" section, showing its date.
    private func eventRow(_ ev: KidTask) -> some View {
        HStack(spacing: 12) {
            Text(ev.emoji.isEmpty ? "📝" : ev.emoji).font(.system(size: 24))
            VStack(alignment: .leading, spacing: 2) {
                Text(ev.title)
                if let iso = ev.targetDate {
                    Text(formattedDate(iso)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let c = ev.countdownText { Text(c).font(.caption.bold()).foregroundStyle(.pink) }
            if settings.canModify(ev) {
                Button { delete(ev) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }

    private func formattedDate(_ iso: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: iso) else { return iso }
        return d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    private func complete(_ task: KidTask) {
        if task.done {
            Task { busy = true; do { try await api.toggle(id: task.id, minutes: nil); await load() } catch let e { error = errorMessage(e) }; busy = false }
        } else {
            minutesTask = task
        }
    }

    private func delete(_ task: KidTask) {
        Task { busy = true; do { try await api.delete(id: task.id); await load() } catch let e { error = errorMessage(e) }; busy = false }
    }

    private func errorMessage(_ e: Error) -> String { (e as? LocalizedError)?.errorDescription ?? e.localizedDescription }
}

/// Small sheet asking how many minutes the task took.
struct MinutesSheet: View {
    let task: KidTask
    let onSave: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var minutes = ""

    var body: some View {
        VStack(spacing: 14) {
            Text("⏱ How long did it take?")
                .font(.title3).bold()
            Text("\(task.emoji) \(task.title)")
                .foregroundStyle(.secondary)
            TextField("minutes", text: $minutes)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
                .multilineTextAlignment(.center)
            HStack {
                Button("Cancel") { dismiss() }
                Button("Save") {
                    let m = Int(minutes) ?? 0
                    dismiss()
                    onSave(max(0, m))
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
    }
}
