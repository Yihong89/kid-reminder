import SwiftUI

struct ReleaseInfo: Codable {
    let tagName: String
    let htmlUrl: String
    let assets: [Asset]
    struct Asset: Codable {
        let name: String
        let browserDownloadUrl: String
    }
    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlUrl = "html_url"
        case assets
    }
    var zipDownloadURL: URL? {
        assets.first { $0.name.hasSuffix(".zip") }
            .flatMap { URL(string: $0.browserDownloadUrl) }
    }
}

/// Checks GitHub Releases for a newer version and can auto-download + install it.
@MainActor
final class AppUpdater: ObservableObject {
    enum State {
        case idle
        case checking
        case available(ReleaseInfo)
        case downloading
        case installing
        case upToDate
        case failed(String)
    }

    @Published var state: State = .idle

    private let api = "https://api.github.com/repos/Yihong89/kid-reminder/releases/latest"

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    func check() async {
        state = .checking
        do {
            var req = URLRequest(url: URL(string: api)!)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, _) = try await URLSession.shared.data(for: req)
            let release = try JSONDecoder().decode(ReleaseInfo.self, from: data)
            state = isNewer(release.tagName, than: currentVersion) ? .available(release) : .upToDate
        } catch {
            state = .failed("Couldn't check for updates — check your internet connection and try again.")
        }
    }

    func update(to release: ReleaseInfo) async {
        guard let url = release.zipDownloadURL else {
            state = .failed("No download found in the release")
            return
        }
        state = .downloading
        do {
            let (temp, _) = try await URLSession.shared.download(from: url)
            let workDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("kidreminder-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            let zipPath = workDir.appendingPathComponent("update.zip")
            try FileManager.default.moveItem(at: temp, to: zipPath)
            try await unzip(zipPath, to: workDir)
            let apps = (try? FileManager.default.contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil)) ?? []
            guard let newApp = apps.first(where: { $0.pathExtension == "app" }) else {
                state = .failed("The downloaded archive didn't contain an app")
                return
            }
            state = .installing
            try install(newApp)
        } catch {
            state = .failed("Update failed: \(error.localizedDescription)")
        }
    }

    private func unzip(_ zip: URL, to dir: URL) async throws {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-x", "-k", zip.path, dir.path]
            p.terminationHandler = { proc in
                if proc.terminationStatus == 0 { cont.resume() } else { cont.resume(throwing: APIError.network("unzip failed")) }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }

    /// Write a helper script that waits for us to quit, swaps in the new app,
    /// and relaunches. Then quit ourselves so the swap can happen.
    private func install(_ newApp: URL) throws {
        let current = Bundle.main.bundleURL
        let helper = FileManager.default.temporaryDirectory.appendingPathComponent("kidreminder-updater.sh")
        let script = """
        #!/bin/bash
        CURRENT="\(current.path)"
        NEW="\(newApp.path)"
        sleep 1
        osascript -e 'quit app "KidReminder"' 2>/dev/null
        for i in $(seq 1 40); do pgrep -x KidReminder >/dev/null || break; sleep 0.5; done
        pkill -x KidReminder 2>/dev/null
        sleep 1
        xattr -dr com.apple.quarantine "$NEW" 2>/dev/null
        PARENT=$(dirname "$CURRENT")
        rm -rf "$CURRENT"
        cp -R "$NEW" "$PARENT/KidReminder.app"
        open "$PARENT/KidReminder.app"
        exit 0
        """
        try script.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [helper.path]
        try p.run()
        NSApplication.shared.terminate(nil)
    }

    private func isNewer(_ tag: String, than current: String) -> Bool {
        let a = versionComponents(tag)
        let b = versionComponents(current)
        let n = max(a.count, b.count)
        for i in 0..<n {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private func versionComponents(_ s: String) -> [Int] {
        s.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }
}
