import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @StateObject private var updater = AppUpdater()
    @State private var host = ""
    @State private var port = ""
    @State private var pin = ""
    @State private var busy = false
    @State private var statusMessage: String?
    @State private var devLogCopyMessage: String?

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

            Section("Updates") {
                LabeledContent("Current version", value: updater.currentVersion)
                switch updater.state {
                case .idle, .checking:
                    Button("Check for Updates") { Task { await updater.check() } }
                        .disabled(ifChecking(updater.state))
                case .available(let release):
                    LabeledContent("New version", value: release.tagName)
                    Button("Download & Update") { Task { await updater.update(to: release) } }
                        .keyboardShortcut(.defaultAction)
                case .downloading:
                    HStack { ProgressView().controlSize(.small); Text("Downloading…") }
                case .installing:
                    HStack { ProgressView().controlSize(.small); Text("Installing…") }
                case .upToDate:
                    Text("You're up to date ✓").foregroundStyle(.secondary)
                case .failed(let msg):
                    Text(msg).foregroundStyle(.secondary).font(.callout)
                    Button("Try again") { Task { await updater.check() } }
                }
            }

            Section("开发者日志") {
                Text("记录听写朗读等功能的内部事件，方便排查偶发问题（比如卡住不动）。平时不影响使用。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("复制日志到剪贴板") {
                        let text = DevLog.contents()
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        devLogCopyMessage = "已复制（\(text.count) 字符）"
                    }
                    Button("在 Finder 中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([DevLog.fileURL])
                    }
                    Button("清空日志", role: .destructive) {
                        DevLog.clear()
                        devLogCopyMessage = "已清空"
                    }
                    Spacer()
                    if let devLogCopyMessage {
                        Text(devLogCopyMessage).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onAppear { Task { await updater.check() } }
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

    private func ifChecking(_ s: AppUpdater.State) -> Bool {
        if case .checking = s { return true }
        return false
    }
}
