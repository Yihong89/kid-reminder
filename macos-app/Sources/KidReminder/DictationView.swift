import SwiftUI

/// 📝 听写 (dictation): the app reads each word + example sentence aloud via
/// server-side TTS; the screen deliberately never shows the character/word
/// text — the kid writes it down on paper. A parent grades it later in the
/// web admin panel, which is where ✓/✗ answers live.
struct DictationView: View {
    @EnvironmentObject var settings: SettingsStore
    @StateObject private var player = DictationAudioPlayer()

    private enum Phase: Equatable {
        case idle
        case starting
        case running(index: Int)
        case finishing
        case done
        case error(String)
    }

    @State private var phase: Phase = .idle
    @State private var session: DictationSession?
    // If playback (loading or actually playing) doesn't wrap up within a few seconds,
    // offer a manual way out — covers whatever's actually stuck (network hang, a
    // rare AVAudioPlayer finish-delegate that never fires, anything else) without
    // needing to know which. `stop()` always resets the player's own state, so this
    // is guaranteed to work even when the automatic recovery paths don't.
    @State private var showRecoveryHint = false
    @State private var recoveryToken = 0
    @State private var recoveryHintTimer: Timer?

    private var api: APIClient { APIClient(settings: settings) }

    var body: some View {
        content
            .navigationTitle("听写")
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        if settings.host.isEmpty || settings.pin.isEmpty {
            ContentUnavailableView("Not connected",
                systemImage: "antenna.radiowaves.left.and.right.slash",
                description: Text("Enter the server address and PIN in Settings."))
        } else {
            switch phase {
            case .idle:
                idleView
            case .starting:
                ProgressView("正在生成听写表…")
            case .running(let index):
                runningView(index: index)
            case .finishing:
                ProgressView("正在提交…")
            case .done:
                doneView
            case .error(let message):
                errorView(message)
            }
        }
    }

    private var idleView: some View {
        VStack(spacing: 16) {
            Text("📝").font(.system(size: 56))
            Text("准备好听写了吗？").font(.title2).bold()
            Text("会随机抽10个字、每字最多3个词，App 会念出来，写在纸上就好。")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            Button("🔊 开始听写") { Task { await start() } }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }

    private func runningView(index: Int) -> some View {
        let total = session?.items.count ?? 0
        let isLast = index >= total - 1
        return VStack(spacing: 20) {
            Text("第 \(index + 1) 题 / 共 \(total) 题")
                .font(.title2).bold()
            Group {
                if player.isLoading {
                    ProgressView().controlSize(.large)
                } else {
                    Image(systemName: player.isPlaying ? "waveform" : "speaker.wave.2.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.blue)
                        .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                }
            }
            .frame(height: 56)
            Text(player.isLoading ? "准备中，马上就好…" : player.isPlaying ? "正在朗读…" : "写完了吗？")
                .foregroundStyle(.secondary)
            HStack(spacing: 14) {
                Button("🔁 重听") { playCurrent(index: index) }
                    .disabled(player.isBusy)
                Button(isLast ? "✅ 完成听写" : "➡️ 下一题") {
                    if isLast { Task { await finish() } }
                    else { advance(to: index + 1) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(player.isBusy)
            }
            if showRecoveryHint {
                Button("卡住了？点这里重试这道题") { forceRetry(index: index) }
                    .font(.footnote)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: index) { if index == 0 { playCurrent(index: index) } }
        .onChange(of: player.isBusy) { _, busy in
            // The recovery hint can appear while genuinely still playing a long clip
            // (isBusy > 6s isn't itself abnormal) — once playback actually wraps up,
            // by whatever path, hide it again instead of leaving it stuck showing.
            if !busy { showRecoveryHint = false }
        }
    }

    private var doneView: some View {
        VStack(spacing: 16) {
            Text("🎉").font(.system(size: 56))
            Text("听写完成！").font(.title2).bold()
            Text("已经提交给家长了，等家长批改后正确数就会更新。")
                .foregroundStyle(.secondary)
            Button("再听写一次") { reset() }
                .buttonStyle(.bordered)
        }
    }

    private func errorView(_ message: String) -> some View {
        ContentUnavailableView("出错了", systemImage: "exclamationmark.triangle",
            description: Text(message))
            .overlay(alignment: .bottom) {
                Button("重试") { reset() }.buttonStyle(.bordered).padding(.bottom, 40)
            }
    }

    // MARK: - actions

    private func start() async {
        phase = .starting
        do {
            let s = try await api.startDictation()
            guard !s.items.isEmpty else { phase = .error("生词库还是空的，请先在网页端添加生词。"); return }
            session = s
            phase = .running(index: 0)
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    private func playCurrent(index: Int) {
        guard let items = session?.items, items.indices.contains(index),
              let url = api.dictationAudioURL(wordId: items[index].wordId) else { return }
        DevLog.log("DictationView playCurrent index=\(index) wordId=\(items[index].wordId)")
        showRecoveryHint = false
        recoveryToken += 1
        let token = recoveryToken
        recoveryHintTimer?.invalidate()
        player.play(url: url)
        // Timer, not Task.sleep — dev-log evidence pointed at Task/async scheduling itself
        // occasionally stalling on this machine (see DictationAudioPlayer.swift), so this
        // recovery mechanism deliberately avoids the same tool that needed recovering from.
        let timer = Timer(timeInterval: 6, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard token == recoveryToken, player.isBusy else { return } // wrapped up normally
                DevLog.log("DictationView recovery hint shown index=\(index) (still busy after 6s)")
                showRecoveryHint = true
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        recoveryHintTimer = timer
    }

    private func forceRetry(index: Int) {
        DevLog.log("DictationView forceRetry tapped index=\(index)")
        player.stop()
        playCurrent(index: index)
    }

    private func advance(to index: Int) {
        phase = .running(index: index)
        playCurrent(index: index)
    }

    private func finish() async {
        guard let sessionId = session?.sessionId else { return }
        phase = .finishing
        do {
            try await api.completeDictation(sessionId: sessionId)
            phase = .done
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    private func reset() {
        player.stop()
        recoveryHintTimer?.invalidate()
        recoveryHintTimer = nil
        session = nil
        phase = .idle
    }
}
