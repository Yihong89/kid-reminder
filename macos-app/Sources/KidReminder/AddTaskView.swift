import SwiftUI

struct AddTaskView: View {
    let onSaved: () -> Void
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var emoji = ""
    @State private var repeatType = "once"
    @State private var date = Date()
    @State private var countdownEnabled = false
    @State private var countdownDays = 7
    @State private var busy = false
    @State private var error: String?

    private let repeats = ["daily", "weekly", "biweekly", "monthly", "once"]
    private var api: APIClient { APIClient(settings: settings) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("➕ New task").font(.title3).bold()

            TextField("Task name", text: $title)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 340)

            HStack(spacing: 16) {
                Picker("Emoji", selection: $emoji) {
                    ForEach(EmojiChoices, id: \.0) { e, label in
                        Text(e.isEmpty ? "😶  none" : "\(e)  \(label)").tag(e)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 250)

                Picker("Repeat", selection: $repeatType) {
                    ForEach(repeats, id: \.self) { r in
                        Text(r.capitalized).tag(r)
                    }
                }
                .pickerStyle(.menu)
            }

            HStack(spacing: 16) {
                DatePicker("Date", selection: $date, displayedComponents: .date)
                    .labelsHidden()
                Toggle("Countdown", isOn: $countdownEnabled)
                if countdownEnabled {
                    Stepper("\(countdownDays) days", value: $countdownDays, in: 1...30)
                }
            }
            .frame(maxWidth: 340)

            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func create() {
        Task {
            busy = true
            defer { busy = false }
            do {
                try await api.addTask(
                    title: title.trimmingCharacters(in: .whitespaces),
                    emoji: emoji.trimmingCharacters(in: .whitespaces),
                    repeatType: repeatType,
                    targetDate: countdownEnabled ? Self.iso(date) : nil,
                    countdownEnabled: countdownEnabled,
                    countdownStart: countdownDays)
                dismiss()
                onSaved()
            } catch let e {
                error = (e as? LocalizedError)?.errorDescription ?? e.localizedDescription
            }
        }
    }

    static func iso(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}
