import SwiftUI

struct CountdownView: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var events: [KidTask] = []
    @State private var error: String?
    @State private var busy = false
    @State private var refreshKey = 0
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
            } else if events.isEmpty {
                ContentUnavailableView("No countdown events",
                    systemImage: "timer",
                    description: Text("Add a task with a date + countdown on the web panel."))
                .toolbar { reloadToolbar }
            } else {
                List(events) { event in eventRow(event) }
                    .toolbar { reloadToolbar }
            }
        }
        .navigationTitle("Countdown")
        .sheet(item: $minutesTask) { task in
            MinutesSheet(task: task) { minutes in
                Task {
                    busy = true
                    do {
                        try await api.toggle(id: task.id, minutes: minutes)
                        SoundEffects.playDone(host: settings.host, port: settings.port)
                        await load()
                    }
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
        }
    }

    private func load() async {
        busy = true
        defer { busy = false }
        do {
            events = try await api.tasks(type: "countdown").sorted {
                ($0.daysLeft ?? .max) < ($1.daysLeft ?? .max)
            }
            error = nil
        } catch let e {
            error = errorMessage(e)
        }
    }

    private func eventRow(_ event: KidTask) -> some View {
        HStack(spacing: 12) {
            Text(event.emoji.isEmpty ? "📝" : event.emoji).font(.system(size: 26))
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .strikethrough(event.done)
                    .foregroundStyle(event.done ? .secondary : .primary)
                if let c = event.countdownText {
                    Text(c).font(.caption.bold()).foregroundStyle(countdownColor(event.daysLeft ?? 0))
                }
            }
            RepeatBadge(task: event)
            Spacer()
            if settings.canModify(event) {
                Button { delete(event) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
            // only check off on/after the event day
            let canComplete = (event.daysLeft ?? .max) <= 0
            Button(event.done ? "Undo" : "Done") { complete(event) }
                .buttonStyle(.borderedProminent)
                .tint(event.done ? .gray : .green)
                .disabled(!canComplete && !event.done)
        }
        .padding(.vertical, 6)
    }

    private func countdownColor(_ daysLeft: Int) -> Color {
        if daysLeft < 0 || daysLeft == 0 { return .red }
        return .blue
    }

    private func complete(_ event: KidTask) {
        if event.done {
            Task { busy = true; do { try await api.toggle(id: event.id, minutes: nil); await load() } catch let e { error = errorMessage(e) }; busy = false }
        } else {
            minutesTask = event
        }
    }

    private func delete(_ event: KidTask) {
        Task { busy = true; do { try await api.delete(id: event.id); await load() } catch let e { error = errorMessage(e) }; busy = false }
    }

    private func errorMessage(_ e: Error) -> String { (e as? LocalizedError)?.errorDescription ?? e.localizedDescription }
}
