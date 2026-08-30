import AVFoundation
import Foundation

/// Plays one dictation-item audio clip at a time (word + example sentence,
/// synthesized server-side). Unlike `SoundEffects` (fire-and-forget chimes),
/// this needs to know when playback *finishes* so the dictation view can
/// unlock its "下一题" button, so it keeps the player alive as a property
/// and uses `AVAudioPlayerDelegate` instead of a bare `Task { play() }`.
@MainActor
final class DictationAudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    /// Fetching/synthesizing audio — on a cache miss this can take several
    /// seconds (real TTS generation), well before any sound exists.
    @Published private(set) var isLoading = false
    /// Actually producing sound right now.
    @Published private(set) var isPlaying = false

    /// True for the whole "don't let the kid skip ahead yet" window —
    /// covers both the fetch/generation wait and actual playback. Views
    /// should disable 重听/下一题 on this, not just `isPlaying`, or a slow
    /// first-time synthesis leaves the buttons tappable while nothing has
    /// been read aloud yet.
    var isBusy: Bool { isLoading || isPlaying }

    private var player: AVAudioPlayer?
    private var onFinish: (() -> Void)?
    private var playToken = 0 // invalidates stale completions from a superseded play()/stop()

    func play(url: URL, onFinish: (() -> Void)? = nil) {
        stop()
        playToken += 1
        let token = playToken
        self.onFinish = onFinish
        isLoading = true
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard token == playToken else { return } // superseded while we were fetching
                isLoading = false
                let p = try AVAudioPlayer(data: data)
                p.delegate = self
                player = p
                isPlaying = p.play()
                if !isPlaying { finish() }
            } catch {
                guard token == playToken else { return }
                isLoading = false
                finish()
            }
        }
    }

    func stop() {
        playToken += 1
        player?.stop()
        player = nil
        isLoading = false
        isPlaying = false
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in finish() }
    }

    private func finish() {
        isPlaying = false
        isLoading = false
        let cb = onFinish
        onFinish = nil
        cb?()
    }
}
