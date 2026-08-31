import SwiftUI

/// Plays through one 自定义听写表 in a fixed order — no grading, no session state on
/// the server, so it can be repeated any number of times. Same audio player/screen
/// language as the standard 30-word DictationView, minus the grading hand-off.
struct CustomDictationPracticeView: View {
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    let list: DictationList
    @StateObject private var player = DictationAudioPlayer()

    private enum Phase: Equatable {
        case loading
        case running(index: Int)
        case done
        case error(String)
    }
    @State private var phase: Phase = .loading
    @State private var items: [DictationListItem] = []

    private var api: APIClient { APIClient(settings: settings) }

    var body: some View {
        content
            .navigationTitle(list.name)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            ProgressView()
        case .running(let index):
            runningView(index: index)
        case .done:
            doneView
        case .error(let message):
            ContentUnavailableView("出错了", systemImage: "exclamationmark.triangle",
                description: Text(message))
        }
    }

    private func runningView(index: Int) -> some View {
        let total = items.count
        let isLast = index >= total - 1
        return VStack(spacing: 20) {
            Text("第 \(index + 1) 条 / 共 \(total) 条")
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
                Button(isLast ? "✅ 完成" : "➡️ 下一条") {
                    if isLast {
                        player.stop()
                        phase = .done
                    } else {
                        phase = .running(index: index + 1)
                        playCurrent(index: index + 1)
                    }
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
            Text("完成！").font(.title2).bold()
            Text("可以点「再听一次」反复练习，随时可以关闭。")
                .foregroundStyle(.secondary)
            Button("🔁 再听一次") { phase = .running(index: 0) }
                .buttonStyle(.borderedProminent)
            Button("关闭") { dismiss() }
                .buttonStyle(.bordered)
        }
    }

    private func playCurrent(index: Int) {
        guard items.indices.contains(index),
              let url = api.customDictationAudioURL(itemId: items[index].id) else { return }
        player.play(url: url)
    }

    private func load() async {
        do {
            items = try await api.dictationListDetail(id: list.id).items
            guard !items.isEmpty else { phase = .error("这张听写表还没有内容。"); return }
            phase = .running(index: 0)
        } catch {
            phase = .error(error.localizedDescription)
        }
    }
}
