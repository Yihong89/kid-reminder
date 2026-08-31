import SwiftUI

/// 📋 听写记录: read-only history of the kid's own graded dictation sets, so they can
/// see which words they got wrong without needing the parent's web admin. Only shows
/// graded sessions — nothing to look at until a parent has graded one.
struct DictationHistoryView: View {
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    private enum LoadState {
        case loading
        case loaded([DictationSessionSummary])
        case error(String)
    }
    @State private var state: LoadState = .loading

    private var api: APIClient { APIClient(settings: settings) }

    var body: some View {
        content
            .navigationTitle("📋 我的听写记录")
            .frame(minWidth: 420, minHeight: 420)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .onAppear { DevLog.log("DictationHistoryView appeared") }
            .task {
                DevLog.log("DictationHistoryView task started, host=\(settings.host) port=\(settings.port) isAdmin=\(settings.isAdmin)")
                await load()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView()
        case .error(let message):
            ContentUnavailableView("加载失败", systemImage: "exclamationmark.triangle",
                description: Text(message))
        case .loaded(let sessions):
            if sessions.isEmpty {
                ContentUnavailableView("还没有批改好的听写", systemImage: "checkmark.circle",
                    description: Text("做完听写后，等家长在网页端批改，结果就会显示在这里。"))
            } else {
                List(sessions) { session in
                    NavigationLink {
                        DictationSessionDetailView(sessionId: session.id)
                    } label: {
                        row(session)
                    }
                }
            }
        }
    }

    private func row(_ s: DictationSessionSummary) -> some View {
        let total = s.itemCount ?? 0
        let correct = s.correctCount ?? 0
        return HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(s.completedAt ?? s.createdAt).font(.subheadline)
                Text("\(total) 个词").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("✅ \(correct)/\(total)")
                .font(.callout).bold()
                .foregroundStyle(total > 0 && correct == total ? .green : .primary)
        }
        .padding(.vertical, 2)
    }

    private func load() async {
        do {
            let sessions = try await api.dictationSessions(status: "graded")
            DevLog.log("DictationHistoryView load() succeeded, \(sessions.count) sessions: \(sessions.map(\.id))")
            state = .loaded(sessions)
        } catch {
            DevLog.log("DictationHistoryView load() FAILED: \(error)")
            state = .error(error.localizedDescription)
        }
    }
}

/// One session's per-word ✓/✗ breakdown.
struct DictationSessionDetailView: View {
    @EnvironmentObject var settings: SettingsStore
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
            .task { await load() }
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
            state = .loaded(detail)
        } catch {
            state = .error(error.localizedDescription)
        }
    }
}
