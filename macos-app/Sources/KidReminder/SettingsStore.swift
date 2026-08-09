import SwiftUI
import Combine

/// Live settings. The API client reads these values on every request, so
/// changing any of them takes effect immediately without restarting the app.
@MainActor
final class SettingsStore: ObservableObject {
    @Published var host: String
    @Published var port: Int
    @Published var pin: String
    @Published var role: String?   // "admin" | "kid" | nil (unknown until verified)
    @Published var connected = false
    @Published var lastError: String?

    private let defaults = UserDefaults.standard

    init() {
        host = defaults.string(forKey: "host") ?? ""
        let p = defaults.integer(forKey: "port")
        port = p == 0 ? 2021 : p
        pin = defaults.string(forKey: "pin") ?? ""
        role = defaults.string(forKey: "role")
        connected = defaults.bool(forKey: "connected")
    }

    func save() {
        defaults.set(host, forKey: "host")
        defaults.set(port, forKey: "port")
        defaults.set(pin, forKey: "pin")
        defaults.set(role, forKey: "role")
        defaults.set(connected, forKey: "connected")
    }

    var isAdmin: Bool { role == "admin" }

    /// A task the current user may edit/delete: admin always; the kid only
    /// for tasks they created themselves.
    func canModify(_ task: KidTask) -> Bool {
        isAdmin || task.createdBy == "kid"
    }
}
