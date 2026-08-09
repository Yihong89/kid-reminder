import SwiftUI

struct AddTaskView: View {
    let onSaved: () -> Void
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var emoji = ""
    @State private var repeatType = "daily"
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
                TextField("emoji", text: $emoji)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)

                Picker("Repeat", selection: $repeatType) {
                    ForEach(repeats, id: \.self) { r in Text(r.capitalized) }
                }
                .pickerStyle(.menu)
            }

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
        .frame(width: 380)
    }

    private func create() {
        Task {
            busy = true
            defer { busy = false }
            do {
                try await api.addTask(
                    title: title.trimmingCharacters(in: .whitespaces),
                    emoji: emoji.trimmingCharacters(in: .whitespaces),
                    repeatType: repeatType)
                dismiss()
                onSaved()
            } catch let e {
                error = (e as? LocalizedError)?.errorDescription ?? e.localizedDescription
            }
        }
    }
}
