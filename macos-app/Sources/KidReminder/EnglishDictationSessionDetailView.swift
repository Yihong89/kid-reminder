import SwiftUI

/// One graded English dictation session's per-word ✓/✗ breakdown — the English
/// counterpart to `DictationSessionDetailView`, minus the character/pinyin line
/// (English `vocab_words` rows store those as empty strings; this view just
/// never renders them, rather than showing blank UI for an empty string).
struct EnglishDictationSessionDetailView: View {
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
            .frame(minWidth: 420, minHeight: 420)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .task { await load() }
    }

    private var title: String {
        guard case .loaded(let detail) = state else { return "英语听写详情" }
        let correct = detail.items.filter { $0.result == "correct" }.count
        return "英语听写详情（\(correct)/\(detail.items.count) 对）"
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
            List(detail.items) { item in
                itemRow(item)
            }
        }
    }

    private func itemRow(_ item: DictationSessionDetailItem) -> some View {
        let isCorrect = item.result == "correct"
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.word).font(.headline)
                Text(item.sentence).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: isCorrect ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(isCorrect ? .green : .red)
                .font(.title3)
        }
        .padding(.vertical, 4)
    }

    private func load() async {
        do {
            let detail = try await api.dictationSessionDetail(id: sessionId)
            state = .loaded(detail)
        } catch {
            state = .error(error.localizedDescription)
        }
    }
}
