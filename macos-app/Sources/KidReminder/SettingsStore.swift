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
    /// Font scale (1.0 = normal) for the paper-runner reading text. The kid can
    /// zoom the passage/prompts with A− / A+ in the runner toolbar.
    @Published var paperFontScale: CGFloat

    /// Google Classroom 作业面板用的 Web App 地址和访问密钥。
    ///
    /// 刻意存在本机 UserDefaults、**只由 app 自己使用**，不经过后端服务器：
    /// 后端 listen 在 0.0.0.0 上、走明文 HTTP、用共享 PIN 认证，
    /// 把 secret 交给它等于对整个局域网（包括学校 WiFi）开放孩子的作业清单。
    @Published var classroomURL: String
    @Published var classroomSecret: String
    static let paperFontRange: ClosedRange<CGFloat> = 0.8...1.8

    private let defaults = UserDefaults.standard

    init() {
        host = defaults.string(forKey: "host") ?? ""
        let p = defaults.integer(forKey: "port")
        port = p == 0 ? 2021 : p
        pin = defaults.string(forKey: "pin") ?? ""
        role = defaults.string(forKey: "role")
        connected = defaults.bool(forKey: "connected")
        let f = defaults.double(forKey: "paperFontScale")
        paperFontScale = f == 0 ? 1.0 : CGFloat(f)
        classroomURL = defaults.string(forKey: "classroomURL") ?? ""
        classroomSecret = defaults.string(forKey: "classroomSecret") ?? ""
    }

    func save() {
        defaults.set(host, forKey: "host")
        defaults.set(port, forKey: "port")
        defaults.set(pin, forKey: "pin")
        defaults.set(role, forKey: "role")
        defaults.set(connected, forKey: "connected")
        defaults.set(paperFontScale, forKey: "paperFontScale")
        defaults.set(classroomURL, forKey: "classroomURL")
        defaults.set(classroomSecret, forKey: "classroomSecret")
    }

    var isAdmin: Bool { role == "admin" }

    /// A task the current user may edit/delete: admin always; the kid only
    /// for tasks they created themselves.
    func canModify(_ task: KidTask) -> Bool {
        isAdmin || task.createdBy == "kid"
    }
}
