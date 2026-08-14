import AVFoundation
import Foundation

/// 🎵 Small shared sound player for celebration effects.
/// Plays WAVs served by the backend (/sounds/...) — no files bundled in the app.
@MainActor
enum SoundEffects {
    /// The cheerful "task done" chime.
    static func playDone(host: String, port: Int) {
        play(url: soundURL(host: host, port: port, file: "done.wav"))
    }

    /// The unlock fanfare.
    static func playFanfare(host: String, port: Int) {
        play(url: soundURL(host: host, port: port, file: "fanfare.wav"))
    }

    private static func soundURL(host: String, port: Int, file: String) -> URL? {
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = host
        comps.port = port
        comps.path = "/sounds/\(file)"
        return comps.url
    }

    private static func play(url: URL?) {
        guard let url else { return }
        Task {
            let player = try? AVAudioPlayer(contentsOf: url)
            player?.volume = 0.8
            player?.play()
        }
    }
}
