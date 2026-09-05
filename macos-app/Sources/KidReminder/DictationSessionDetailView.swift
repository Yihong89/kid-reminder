import SwiftUI

/// One graded session's per-word ✓/✗ breakdown, so the kid can see which words they got
/// wrong without needing the parent's web admin.
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
            // Load-bearing: a macOS sheet sizes to its content's fitting size, and a short
            // List is small enough to read as blank without this. See DictationView's
            // sheet comment for the full story.
            .frame(minWidth: 420, minHeight: 420)
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
            List(detail.items) { item in
                itemRow(item)
            }
        }
    }

    private func itemRow(_ item: DictationSessionDetailItem) -> some View {
        let isCorrect = item.result == "correct"
        return HStack(alignment: .top, spacing: 12) {
            Text(item.character)
                .font(.title2).bold()
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.word).font(.headline)
                    Text(item.pinyin).font(.caption).foregroundStyle(.secondary)
                }
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
            DevLog.log("DictationSessionDetailView load() succeeded sessionId=\(sessionId), \(detail.items.count) items")
            state = .loaded(detail)
        } catch {
            DevLog.log("DictationSessionDetailView load() FAILED sessionId=\(sessionId): \(error)")
            state = .error(error.localizedDescription)
        }
    }
}
