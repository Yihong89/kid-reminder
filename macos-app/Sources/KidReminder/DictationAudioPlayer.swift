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
        DevLog.log("play() token=\(token) url=\(url.lastPathComponent)")
        Task {
            do {
                let start = Date()
                let (data, response) = try await URLSession.shared.data(from: url)
                let elapsed = Date().timeIntervalSince(start)
                guard token == playToken else {
                    DevLog.log("play() token=\(token) fetch done after \(elapsed)s but superseded (current token=\(playToken)) — ignoring")
                    return // superseded while we were fetching
                }
                // `data(from:)` only throws for network-level failures — a 5xx from our own
                // server (e.g. the shared TTS service was briefly backlogged) still "succeeds"
                // here, with the JSON error body as `data`. Feeding that to AVAudioPlayer used
                // to sometimes leave it stuck reporting isPlaying with no audio and no finish
                // callback (no valid audio to finish playing), instead of failing loudly — so
                // check the status explicitly rather than trusting any 200-byte response is audio.
                let statusCode = (response as? HTTPURLResponse)?.statusCode
                DevLog.log("play() token=\(token) fetch done in \(elapsed)s status=\(statusCode.map(String.init) ?? "?") bytes=\(data.count)")
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw APIError.status(http.statusCode)
                }
                isLoading = false
                let p = try AVAudioPlayer(data: data)
                p.delegate = self
                player = p
                isPlaying = p.play()
                DevLog.log("play() token=\(token) AVAudioPlayer created duration=\(p.duration)s play()->\(isPlaying)")
                if !isPlaying {
                    finish()
                } else {
                    armSafetyNet(for: p, token: token)
                }
            } catch {
                guard token == playToken else { return }
                DevLog.log("play() token=\(token) failed: \(error)")
                isLoading = false
                finish()
            }
        }
    }

    // AVAudioPlayer's finish-delegate is expected to always fire once playback
    // reaches the end, but has occasionally been observed not to (a reported
    // symptom: the clip is audibly done, yet the UI stays on "正在朗读" with
    // 下一题 disabled forever — no known reproduction, and the delegate not
    // firing isn't something we can fix from here). Rather than leave the kid
    // stuck indefinitely if it happens again, force-finish a beat after the
    // clip's own duration if the delegate hasn't already done so by then.
    private func armSafetyNet(for p: AVAudioPlayer, token: Int) {
        let deadline = p.duration + 1.5
        DevLog.log("armSafetyNet token=\(token) deadline=\(deadline)s")
        Task {
            try? await Task.sleep(for: .seconds(deadline))
            guard token == self.playToken, self.isPlaying else {
                DevLog.log("armSafetyNet token=\(token) fired but already handled (token now \(self.playToken), isPlaying=\(self.isPlaying))")
                return // already handled normally
            }
            DevLog.log("armSafetyNet token=\(token) FIRED — delegate never called finish()")
            self.finish()
        }
    }

    func stop() {
        playToken += 1
        DevLog.log("stop() new token=\(playToken) hadPlayer=\(player != nil)")
        player?.stop()
        player = nil
        isLoading = false
        isPlaying = false
    }

    nonisolated func audioPlayerDidFinishPlaying(_ finishedPlayer: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            let isCurrent = finishedPlayer === self.player
            DevLog.log("audioPlayerDidFinishPlaying successfully=\(flag) isCurrentPlayer=\(isCurrent)")
            guard isCurrent else { return } // stale/superseded player
            finish()
        }
    }

    private func finish() {
        DevLog.log("finish() token=\(playToken)")
        isPlaying = false
        isLoading = false
        let cb = onFinish
        onFinish = nil
        cb?()
    }
}
