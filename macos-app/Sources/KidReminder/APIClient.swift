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

    func tasks(type: String, date: String? = nil) async throws -> [KidTask] {
        var items: [URLQueryItem] = [URLQueryItem(name: "type", value: type)]
        if let date = date { items.append(URLQueryItem(name: "date", value: date)) }
        var comps = URLComponents()
        comps.queryItems = items
        let path = "/api/tasks" + (comps.percentEncodedQuery.map { "?\($0)" } ?? "")
        let data = try await request(path)
        return try JSONDecoder().decode(TasksResponse.self, from: data).tasks
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

    func addTask(title: String, emoji: String, repeatType: String) async throws {
        let body = try JSONEncoder().encode(["title": title, "emoji": emoji, "repeat": repeatType])
        _ = try await request("/api/tasks", method: "POST", body: body)
    }

    func delete(id: Int) async throws {
        _ = try await request("/api/tasks/\(id)", method: "DELETE")
    }
}
