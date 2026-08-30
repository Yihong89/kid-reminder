import Foundation

/// Lightweight, always-on (not just DEBUG) diagnostic logger. A `#if DEBUG print()`
/// is useless once the app is running on the kid's Mac, out of Xcode's reach — this
/// persists a small rolling log to disk so an intermittent, hard-to-reproduce bug
/// (e.g. dictation's audio player occasionally not registering "finished") leaves a
/// trail we can actually look at afterwards. Exposed via Settings → Developer Log.
enum DevLog {
    private static let queue = DispatchQueue(label: "com.kidreminder.devlog")
    private static let maxBytes = 500_000 // trim rather than grow forever

    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KidReminder", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("dev.log")
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// Fire-and-forget — safe to call from anywhere, never blocks the caller.
    static func log(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            let url = fileURL
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(data)
            } else {
                try? data.write(to: url)
            }
            trimIfNeeded(url)
        }
    }

    private static func trimIfNeeded(_ url: URL) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int,
              size > maxBytes,
              let full = try? String(contentsOf: url, encoding: .utf8) else { return }
        // keep the tail half — recent events matter most for chasing a live bug
        let trimmed = String(full.suffix(maxBytes / 2))
        try? trimmed.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Blocks briefly (file I/O only) so callers get a consistent snapshot after any
    /// in-flight writes — fine for a user-triggered Settings button tap.
    static func contents() -> String {
        queue.sync { (try? String(contentsOf: fileURL, encoding: .utf8)) ?? "(暂无日志)" }
    }

    static func clear() {
        queue.sync { try? FileManager.default.removeItem(at: fileURL) }
    }
}
