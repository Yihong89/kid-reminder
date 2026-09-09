import SwiftUI

/// 🔤 The English dictation runner — always the graded 30-word weakest-first set
/// (no custom-list equivalent yet, unlike the Chinese `DictationRunnerView`). The
/// app reads each word + example sentence aloud via server-side TTS (English
/// voice — see `ensureDictationAudio`'s language branch); the screen never shows
/// the word text, same rule as the Chinese version.
struct EnglishDictationRunnerView: View {
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    @StateObject private var player = DictationAudioPlayer()

    private enum Phase: Equatable {
        case loading
        case running(index: Int)
        case finishing
        case done
        case error(String)
    }

    @State private var phase: Phase = .loading
    @State private var clips: [URL] = []
    @State private var sessionId: Int?

    private var api: APIClient { APIClient(settings: settings) }

    var body: some View {
        content
            .navigationTitle("🔤 英语听写")
            .padding()
            .frame(minWidth: 460, minHeight: 460)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { player.stop(); dismiss() }
                }
            }
            .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView("正在生成听写表…")
        case .running(let index):
            runningView(index: index)
        case .finishing:
            ProgressView("正在提交…")
        case .done:
            doneView
        case .error(let message):
            ContentUnavailableView("出错了", systemImage: "exclamationmark.triangle",
                description: Text(message))
        }
    }

    // MARK: - running

    private func runningView(index: Int) -> some View {
        let total = clips.count
        let isLast = index >= total - 1
        return VStack(spacing: 22) {
            progressHeader(index: index, total: total)

            Spacer(minLength: 0)

            Group {
                if player.isLoading {
                    ProgressView().controlSize(.large)
                } else {
                    Image(systemName: player.isPlaying ? "waveform" : "speaker.wave.2.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.blue)
                        .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                }
            }
            .frame(height: 72)

            Text(player.isLoading ? "准备中，马上就好…" : player.isPlaying ? "正在朗读…" : "写完了吗？")
                .font(.title3)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            HStack(spacing: 16) {
                Button("🔁 重听") { playCurrent(index: index) }
                    .controlSize(.large)
                    .keyboardShortcut(.space, modifiers: [])
                Button(isLast ? "✅ 完成" : "➡️ 下一题") {
                    if isLast { Task { await finish() } }
                    else { advance(to: index + 1) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .disabled(player.isBusy)
        }
        .task(id: index) { if index == 0 { playCurrent(index: index) } }
    }

    private func progressHeader(index: Int, total: Int) -> some View {
        VStack(spacing: 8) {
            Text("第 \(index + 1) 题 / 共 \(total) 题")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .monospacedDigit()
            ProgressView(value: Double(index + 1), total: Double(max(total, 1)))
                .frame(maxWidth: 320)
        }
    }

    private var doneView: some View {
        VStack(spacing: 16) {
            Text("🎉").font(.system(size: 56))
            Text("听写完成！").font(.title2).bold()
            Text("已经提交给家长了，等家长批改后正确数就会更新。")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            Button("关闭") { player.stop(); dismiss() }
                .buttonStyle(.bordered)
        }
    }

    // MARK: - actions

    private func load() async {
        do {
            let session = try await api.startEnglishDictation()
            guard !session.items.isEmpty else {
                phase = .error("英语听写词库还是空的，请先在网页端添加单词。"); return
            }
            sessionId = session.sessionId
            clips = session.items.compactMap { api.dictationAudioURL(wordId: $0.wordId) }
            guard !clips.isEmpty else {
                phase = .error("没能准备好朗读内容，请检查服务器地址。"); return
            }
            phase = .running(index: 0)
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    private func playCurrent(index: Int) {
        guard clips.indices.contains(index) else { return }
        player.play(url: clips[index])
    }

    private func advance(to index: Int) {
        phase = .running(index: index)
        playCurrent(index: index)
    }

    private func finish() async {
        player.stop()
        guard let sessionId else { phase = .done; return }
        phase = .finishing
        do {
            try await api.completeDictation(sessionId: sessionId)
            phase = .done
        } catch {
            phase = .error(error.localizedDescription)
        }
    }
}
