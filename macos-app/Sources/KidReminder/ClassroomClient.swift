import Foundation

enum ClassroomError: LocalizedError {
    case notConfigured
    case badURL
    case http(Int)
    case badSecret
    case noSecret
    case server(String)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "还没填 Web App URL 和 Secret。到 设置 → Google Classroom 里填。"
        case .badURL:
            return "URL 格式不对。应该是 Apps Script 部署后给出的、以 /exec 结尾的地址。"
        case .http(let code):
            return "服务器返回 HTTP \(code)。如果是 401/403，通常是部署时「谁可以访问」没设成 Anyone。"
        case .badSecret:
            return "Secret 不对。回到 Apps Script 编辑器重新运行 installSecret，把新的填进来。"
        case .noSecret:
            return "Apps Script 那边还没生成 secret。在编辑器里运行一次 installSecret。"
        case .server(let msg):
            return msg
        case .decode(let msg):
            return "返回的内容不是预期的 JSON：\(msg)\n\n常见原因：部署时「谁可以访问」没选 Anyone，Google 返回的是登录页而不是数据。"
        }
    }
}

struct ClassroomClient {
    let baseURL: String
    let secret: String

    var isConfigured: Bool {
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func fetch() async throws -> ClassroomPayload {
        guard isConfigured else { throw ClassroomError.notConfigured }

        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var comps = URLComponents(string: trimmed), comps.scheme == "https" else {
            throw ClassroomError.badURL
        }
        var query = comps.queryItems ?? []
        query.append(URLQueryItem(name: "k",
                                  value: secret.trimmingCharacters(in: .whitespacesAndNewlines)))
        comps.queryItems = query
        guard let url = comps.url else { throw ClassroomError.badURL }

        var req = URLRequest(url: url)
        req.timeoutInterval = 40
        req.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw ClassroomError.server("没有拿到 HTTP 响应") }
        guard http.statusCode == 200 else { throw ClassroomError.http(http.statusCode) }

        let payload: ClassroomPayload
        do {
            payload = try JSONDecoder().decode(ClassroomPayload.self, from: data)
        } catch {
            throw ClassroomError.decode(error.localizedDescription)
        }

        guard payload.ok else {
            switch payload.error {
            case "bad_secret": throw ClassroomError.badSecret
            case "no_secret": throw ClassroomError.noSecret
            default:
                throw ClassroomError.server(payload.hint ?? payload.message ?? payload.error ?? "未知错误")
            }
        }
        return payload
    }
}
