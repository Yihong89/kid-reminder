import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var host = ""
    @State private var port = ""
    @State private var pin = ""
    @State private var busy = false
    @State private var statusMessage: String?

    private var api: APIClient { APIClient(settings: settings) }

    var body: some View {
        Form {
            Section("Server") {
                TextField("IP / hostname", text: $host)
                    .textContentType(.none)
                TextField("Port", text: $port)
                    .frame(maxWidth: 120)
            }
            Section("PIN") {
                SecureField("PIN", text: $pin)
                    .frame(maxWidth: 160)
            }
            Section {
                HStack {
                    if busy {
                        ProgressView().controlSize(.small)
                    }
                    Button("Save & Connect") { connect() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(busy)
                    Spacer()
                    if let statusMessage {
                        Text(statusMessage).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let role = settings.role {
                Section("You are signed in as") {
                    Label(role == "admin" ? "Parent (full control)" : "Kid (your own tasks only)",
                          systemImage: role == "admin" ? "person.crop.circle.fill" : "face.smiling")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .onAppear {
            host = settings.host
            port = String(settings.port)
            pin = settings.pin
        }
        .task { await verify() }
    }

    private func connect() {
        settings.host = host.trimmingCharacters(in: .whitespaces)
        settings.port = Int(port.trimmingCharacters(in: .whitespaces)) ?? 2021
        settings.pin = pin.trimmingCharacters(in: .whitespaces)
        settings.save()
        Task { await verify() }
    }

    private func verify() async {
        guard !settings.pin.isEmpty else { return }
        busy = true
        defer { busy = false }
        do {
            let role = try await api.verify()
            settings.role = role
            settings.connected = true
            settings.lastError = nil
            settings.save()
            statusMessage = role == "admin" ? "Connected as parent ✅" : "Connected as kid ✅"
        } catch {
            settings.connected = false
            settings.role = nil
            settings.save()
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            statusMessage = "Could not connect: \(msg)"
        }
    }
}
