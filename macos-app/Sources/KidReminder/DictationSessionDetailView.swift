import SwiftUI

/// One graded session's per-word ✓/✗ breakdown — the kid's 订正 screen. It shows the
/// words they got wrong, large enough to copy from and with every wrong word in red,
/// without needing the parent's web admin.
///
/// Reached from the 听写记录 column in `DictationView`, which lists graded sessions only —
/// this view shows the word text, so it must never be opened for a session that hasn't
/// been graded yet (the whole feature rests on the words staying off-screen until then).
struct DictationSessionDetailView: View {
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    let sessionId: Int

    private enum LoadState {
        case loading
        case loaded(DictationSessionDetail)
        case error(String)
    }
    @State private var state: LoadState = .loading

    private var api: APIClient { APIClient(settings: settings) }

    var body: some View {
        content
            .navigationTitle(title)
            // Wider than the old 420 pt sheet: the word text is now correction-sized
            // (42 pt) and a full example sentence has to wrap underneath it, not sit
            // squeezed next to a 46 pt reference badge.
            .frame(minWidth: 580, minHeight: 500)
            // Presented directly as a sheet now (it used to be pushed onto a NavigationStack
            // inside the history sheet), so it needs its own way out.
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .onAppear { DevLog.log("DictationSessionDetailView appeared sessionId=\(sessionId)") }
            .task {
                DevLog.log("DictationSessionDetailView task started sessionId=\(sessionId)")
                await load()
            }
    }

    private var title: String {
        guard case .loaded(let detail) = state else { return "听写详情" }
        let correct = detail.items.filter { $0.result == "correct" }.count
        return "听写详情（\(correct)/\(detail.items.count) 对）"
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView()
        case .error(let message):
            ContentUnavailableView("加载失败", systemImage: "exclamationmark.triangle",
                description: Text(message))
        case .loaded(let detail):
            VStack(spacing: 0) {
                correctionSummary(detail)
                Divider()
                List(detail.items) { item in
                    DictationCorrectionRow(
                        character: item.character,
                        word: item.word,
                        pinyin: item.pinyin,
                        sentence: item.sentence,
                        isCorrect: item.result == "correct"
                    )
                    // Each row paints its own card background, so the list's default
                    // separators would cut through the red wash of a wrong row.
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
                }
                .listStyle(.inset)
            }
        }
    }

    /// One line above the list that says what to do with the red rows — the list itself
    /// is long (40 words in a normal set), and "which ones are wrong" should not require
    /// scanning it.
    private func correctionSummary(_ detail: DictationSessionDetail) -> some View {
        let wrong = detail.items.filter { $0.result == "incorrect" }.count
        return HStack(spacing: 10) {
            if wrong == 0 {
                Text("🎉 全部写对了，不用订正")
                    .foregroundStyle(.green)
            } else {
                Text("❌ \(wrong) 个错字")
                    .foregroundStyle(.red)
                Text("红色的字就是要订正的")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("共 \(detail.items.count) 个")
                .foregroundStyle(.tertiary)
        }
        .font(.system(size: 16, weight: .semibold))
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func load() async {
        do {
            let detail = try await api.dictationSessionDetail(id: sessionId)
            DevLog.log("DictationSessionDetailView load() succeeded sessionId=\(sessionId), \(detail.items.count) items")
            state = .loaded(detail)
        } catch {
            DevLog.log("DictationSessionDetailView load() FAILED sessionId=\(sessionId): \(error)")
            state = .error(error.localizedDescription)
        }
    }
}
