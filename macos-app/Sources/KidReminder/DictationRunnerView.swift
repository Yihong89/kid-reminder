import SwiftUI

/// Where a dictation run gets its words from. Both 随机听写 and a 自定义听写表's ▶️
/// button open the *same* window (`DictationRunnerView`) — this is the only thing
/// that differs between them.
enum DictationSource: Identifiable {
    /// The graded 30-word set: weakest words first, submitted to the parent for
    /// grading when finished.
    case random
    /// One 自定义听写表: fixed order, ungraded, repeatable as many times as the kid likes.
    case list(DictationList)

    var id: String {
        switch self {
        case .random: return "random"
        case .list(let l): return "list-\(l.id)"
        }
    }

    var title: String {
        switch self {
        case .random: return "🎲 随机听写"
        case .list(let l): return l.name
        }
    }

    /// Counter unit — the graded set is made of 题 (questions), a custom list of 条 (entries).
    var unit: String {
        switch self {
        case .random: return "题"
        case .list: return "条"
        }
    }
}

/// 📝 The one dictation window. The app reads each word + example sentence aloud via
/// server-side TTS; the screen deliberately never shows the character/word text — the
/// kid writes it down on paper.
///
/// Both entry points land here so the running screen exists exactly once. `load()`
/// normalizes either source into a plain `[URL]` of clips, after which nothing below
/// needs to know which kind of dictation this is.
struct DictationRunnerView: View {
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    let source: DictationSource

    @StateObject private var player = DictationAudioPlayer()

    private enum Phase: Equatable {
        case loading
        case running(index: Int)
        case finishing
        case done
        case error(String)
    }

    @State private var phase: Phase = .loading
    /// Playable clips in playback order — the normalized form of both sources.
    @State private var clips: [URL] = []
    /// Set only for `.random`; the graded set has to be handed back for grading.
    @State private var sessionId: Int?

    private var api: APIClient { APIClient(settings: settings) }

    var body: some View {
        content
            .navigationTitle(source.title)
            .padding()
            // Load-bearing: on macOS a sheet sizes itself to its content's *fitting*
            // size, and short content renders small enough to read as blank. Removing
            // this reintroduces the blank-sheet bug (see DictationView's sheet comment).
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
            ProgressView(loadingLabel)
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

    private var loadingLabel: String {
        switch source {
        case .random: return "正在生成听写表…"
        case .list: return "正在准备…"
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
                Button(isLast ? "✅ 完成" : "➡️ 下一\(source.unit)") {
                    if isLast { Task { await finish() } }
                    else { advance(to: index + 1) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            // Both disable on isBusy, not isPlaying — a slow first-time TTS synthesis
            // would otherwise leave these tappable before anything has been read aloud.
            .disabled(player.isBusy)
        }
        .task(id: index) { if index == 0 { playCurrent(index: index) } }
    }

    private func progressHeader(index: Int, total: Int) -> some View {
        VStack(spacing: 8) {
            Text("第 \(index + 1) \(source.unit) / 共 \(total) \(source.unit)")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .monospacedDigit()
            ProgressView(value: Double(index + 1), total: Double(max(total, 1)))
                .frame(maxWidth: 320)
        }
    }

    private var doneView: some View {
        VStack(spacing: 16) {
            Text("🎉").font(.system(size: 56))
            Text(isRandom ? "听写完成！" : "完成！").font(.title2).bold()
            Text(isRandom
                 ? "已经提交给家长了，等家长批改后正确数就会更新。"
                 : "可以点「再听一次」反复练习，随时可以关闭。")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            // Only a custom list can be replayed — a graded set is submitted and done.
            if !isRandom {
                Button("🔁 再听一次") { phase = .running(index: 0); playCurrent(index: 0) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            Button("关闭") { player.stop(); dismiss() }
                .buttonStyle(.bordered)
        }
    }

    private var isRandom: Bool {
        if case .random = source { return true }
        return false
    }

    // MARK: - actions

    private func load() async {
        do {
            switch source {
            case .random:
                let session = try await api.startDictation()
                guard !session.items.isEmpty else {
                    phase = .error("生词库还是空的，请先在网页端添加生词。"); return
                }
                sessionId = session.sessionId
                clips = session.items.compactMap { api.dictationAudioURL(wordId: $0.wordId) }
            case .list(let list):
                let items = try await api.dictationListDetail(id: list.id).items
                guard !items.isEmpty else {
                    phase = .error("这张听写表还没有内容。"); return
                }
                clips = items.compactMap { api.customDictationAudioURL(itemId: $0.id) }
            }
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
        DevLog.log("DictationRunner playCurrent source=\(source.id) index=\(index)")
        player.play(url: clips[index])
    }

    private func advance(to index: Int) {
        phase = .running(index: index)
        playCurrent(index: index)
    }

    private func finish() async {
        player.stop()
        // A custom list has no server-side session — finishing is purely local.
        guard isRandom, let sessionId else { phase = .done; return }
        phase = .finishing
        do {
            try await api.completeDictation(sessionId: sessionId)
            phase = .done
        } catch {
            phase = .error(error.localizedDescription)
        }
    }
}
