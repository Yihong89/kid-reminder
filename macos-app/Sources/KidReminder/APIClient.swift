import Foundation

enum APIError: LocalizedError {
    case badURL
    case network(String)
    case status(Int)

    var errorDescription: String? {
        switch self {
        case .badURL: return "Invalid server address"
        case .network(let s): return "Network error: \(s)"
        case .status(let c):
            switch c {
            case 401: return "Wrong PIN"
            case 403: return "Not allowed for this account"
            default: return "Server error (\(c))"
            }
        }
    }
}

/// Small HTTP client. It reads the host/port/pin from SettingsStore on every
/// call, so connection settings apply immediately (no restart needed).
@MainActor
final class APIClient {
    let settings: SettingsStore

    init(settings: SettingsStore) { self.settings = settings }

    private func url(_ path: String) throws -> URL {
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = settings.host
        comps.port = settings.port
        guard let base = comps.url, let u = URL(string: path, relativeTo: base) else {
            throw APIError.badURL
        }
        return u
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        var req = URLRequest(url: try url(path))
        req.httpMethod = method
        req.timeoutInterval = 8
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !settings.pin.isEmpty {
            req.setValue(settings.pin, forHTTPHeaderField: settings.isAdmin ? "X-Admin-Pin" : "X-Kid-Pin")
        }
        if let body = body { req.httpBody = body }
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.network("no response") }
        guard (200..<300).contains(http.statusCode) else { throw APIError.status(http.statusCode) }
        return data
    }

    func verify() async throws -> String {
        struct Req: Encodable { let pin: String }
        struct Resp: Decodable { let role: String }
        let body = try JSONEncoder().encode(Req(pin: settings.pin))
        let data = try await request("/api/verify", method: "POST", body: body)
        return try JSONDecoder().decode(Resp.self, from: data).role
    }

    func tasks(type: String?, date: String? = nil) async throws -> [KidTask] {
        try await tasksResponse(type: type, date: date).tasks
    }

    /// Full /api/tasks response (tasks + allDone + stamped) — used for achievements.
    func tasksResponse(type: String?, date: String? = nil) async throws -> TasksResponse {
        var items: [URLQueryItem] = []
        if let type = type { items.append(URLQueryItem(name: "type", value: type)) }
        if let date = date { items.append(URLQueryItem(name: "date", value: date)) }
        var comps = URLComponents()
        comps.queryItems = items
        let path = "/api/tasks" + (comps.percentEncodedQuery.map { "?\($0)" } ?? "")
        let data = try await request(path)
        return try JSONDecoder().decode(TasksResponse.self, from: data)
    }

    func toggle(id: Int, minutes: Int?) async throws {
        let body: Data
        if let minutes = minutes {
            body = try JSONEncoder().encode(["minutes": minutes])
        } else {
            body = Data("{}".utf8)
        }
        _ = try await request("/api/tasks/\(id)/toggle", method: "POST", body: body)
    }

    func addTask(title: String, emoji: String, repeatType: String,
                 targetDate: String?, countdownEnabled: Bool, countdownStart: Int,
                 parentOnly: Bool = false) async throws {
        struct NewTask: Encodable {
            let title: String
            let emoji: String
            let repeatType: String
            let targetDate: String?
            let countdownEnabled: Bool
            let countdownStart: Int
            let parentOnly: Bool
            enum CodingKeys: String, CodingKey {
                case title, emoji, targetDate, countdownEnabled, countdownStart, parentOnly
                case repeatType = "repeat"
            }
        }
        let payload = NewTask(title: title, emoji: emoji, repeatType: repeatType,
                              targetDate: targetDate, countdownEnabled: countdownEnabled,
                              countdownStart: countdownStart, parentOnly: parentOnly)
        let body = try JSONEncoder().encode(payload)
        _ = try await request("/api/tasks", method: "POST", body: body)
    }

    func delete(id: Int) async throws {
        _ = try await request("/api/tasks/\(id)", method: "DELETE")
    }

    /// ⚡ collection stats (stamp balance + caught Pokémon)
    func stats() async throws -> StatsInfo {
        let data = try await request("/api/stats")
        return try JSONDecoder().decode(StatsInfo.self, from: data)
    }

    /// Spend one stamp to randomly unlock a Pokémon.
    func unlock() async throws -> UnlockResponse {
        let body = Data("{}".utf8)
        let data = try await request("/api/unlock", method: "POST", body: body)
        return try JSONDecoder().decode(UnlockResponse.self, from: data)
    }

    /// URL for a Pokémon sprite served by the backend (/sprites/<dex>.png)
    func spriteURL(dex: Int) -> URL? {
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = settings.host
        comps.port = settings.port
        comps.path = "/sprites/\(dex).png"
        return comps.url
    }

    /// URL for the unlock fanfare served by the backend (/sounds/fanfare.wav)
    func soundURL() -> URL? {
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = settings.host
        comps.port = settings.port
        comps.path = "/sounds/fanfare.wav"
        return comps.url
    }
}
