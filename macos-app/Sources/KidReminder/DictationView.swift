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
    @State private var customLists: [DictationList] = []

    // A single sheet destination instead of one @State + one .sheet modifier per
    // destination — stacking multiple .sheet modifiers on one view is a known SwiftUI
    // flakiness source (can silently present a blank sheet instead of the intended
    // content); one .sheet(item:) driven by this enum sidesteps the whole class of bug.
    private enum SheetDestination: Identifiable {
        case history
        case practiceList(DictationList)
        case createList
        case editList(DictationList)

        var id: String {
            switch self {
            case .history: return "history"
            case .practiceList(let l): return "practice-\(l.id)"
            case .createList: return "createList"
            case .editList(let l): return "edit-\(l.id)"
            }
        }
    }
    @State private var activeSheet: SheetDestination?

    private var api: APIClient { APIClient(settings: settings) }

    var body: some View {
        content
            .navigationTitle("听写")
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .history:
                    NavigationStack { DictationHistoryView() }
                case .practiceList(let list):
                    NavigationStack { CustomDictationPracticeView(list: list) }
                case .createList:
                    NavigationStack { DictationListEditorView(onSaved: { Task { await loadCustomLists() } }) }
                case .editList(let list):
                    NavigationStack { DictationListEditorView(existingList: list, onSaved: { Task { await loadCustomLists() } }) }
                }
            }
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
        ScrollView {
            VStack(spacing: 16) {
                Text("📝").font(.system(size: 56))
                Text("准备好听写了吗？").font(.title2).bold()
                Text("会挑30个最需要练习的词，App 会念出来，写在纸上就好。")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
                Button("🔊 开始听写") { Task { await start() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Button("📋 我的听写记录") { activeSheet = .history }
                    .buttonStyle(.bordered)

                if !customLists.isEmpty {
                    Divider().frame(maxWidth: 300).padding(.top, 8)
                    Text("我的自定义听写表").font(.headline)
                    VStack(spacing: 8) {
                        ForEach(customLists) { list in
                            HStack(spacing: 8) {
                                Button {
                                    activeSheet = .practiceList(list)
                                } label: {
                                    HStack {
                                        Text("▶️ \(list.name)")
                                        Spacer()
                                        Text("\(list.itemCount ?? 0) 条")
                                            .foregroundStyle(.secondary).font(.caption)
                                    }
                                }
                                .buttonStyle(.bordered)
                                Button { activeSheet = .editList(list) } label: { Image(systemName: "pencil") }
                                    .buttonStyle(.bordered)
                            }
                            .frame(maxWidth: 340)
                        }
                    }
                }
                Button("➕ 新建自定义听写表") { activeSheet = .createList }
                    .buttonStyle(.bordered)
            }
            .padding(.vertical, 24)
        }
        .task { await loadCustomLists() }
    }

    private func loadCustomLists() async {
        customLists = (try? await api.dictationLists()) ?? []
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
        }
        .task(id: index) { if index == 0 { playCurrent(index: index) } }
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
        player.play(url: url)
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
        session = nil
        phase = .idle
    }
}
