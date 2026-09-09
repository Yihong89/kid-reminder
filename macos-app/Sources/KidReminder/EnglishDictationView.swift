import SwiftUI

/// 🔤 英语听写 — the browser screen. Single column (unlike the Chinese `DictationView`,
/// which also has a 自定义听写表 column — that's out of scope for English v1, see the
/// plan this was built from). Actually *doing* a dictation happens in
/// `EnglishDictationRunnerView`, presented as a sheet.
struct EnglishDictationView: View {
    @EnvironmentObject var settings: SettingsStore

    @State private var sessions: [DictationSessionSummary] = []
    @State private var historyError: String?
    @State private var loadingHistory = true

    private enum SheetDestination: Identifiable {
        case run
        case sessionDetail(Int)

        var id: String {
            switch self {
            case .run: return "run"
            case .sessionDetail(let id): return "session-\(id)"
            }
        }
    }
    @State private var activeSheet: SheetDestination?

    private var api: APIClient { APIClient(settings: settings) }

    var body: some View {
        content
            .navigationTitle("英语听写")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .sheet(item: $activeSheet) { sheet in
                sheetContent(for: sheet)
            }
    }

    @ViewBuilder
    private func sheetContent(for sheet: SheetDestination) -> some View {
        switch sheet {
        case .run:
            NavigationStack { EnglishDictationRunnerView() }
        case .sessionDetail(let id):
            NavigationStack { EnglishDictationSessionDetailView(sessionId: id) }
        }
    }

    @ViewBuilder
    private var content: some View {
        if settings.host.isEmpty || settings.pin.isEmpty {
            ContentUnavailableView("Not connected",
                systemImage: "antenna.radiowaves.left.and.right.slash",
                description: Text("Enter the server address and PIN in Settings."))
        } else {
            VStack(spacing: 0) {
                header
                Divider()
                historyColumn
            }
            .task { await loadHistory() }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Text("🔤").font(.system(size: 34))
            VStack(alignment: .leading, spacing: 2) {
                Text("英语听写").font(.title3.bold())
                Text("会挑 30 个最需要练习的单词，App 念出来，写在纸上就好。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("🎲 开始英语听写") { activeSheet = .run }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var historyColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            columnHeader("📋 听写记录")
            Group {
                if loadingHistory {
                    centered { ProgressView() }
                } else if let historyError {
                    centered {
                        ContentUnavailableView("加载失败", systemImage: "exclamationmark.triangle",
                            description: Text(historyError))
                    }
                } else if sessions.isEmpty {
                    centered {
                        ContentUnavailableView("还没有批改好的听写", systemImage: "checkmark.circle",
                            description: Text("做完听写后，等家长在网页端批改，结果就会显示在这里。"))
                    }
                } else {
                    List(sessions) { session in
                        Button { activeSheet = .sessionDetail(session.id) } label: {
                            historyRow(session)
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.inset)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func historyRow(_ s: DictationSessionSummary) -> some View {
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
                .monospacedDigit()
                .foregroundStyle(total > 0 && correct == total ? .green : .primary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }

    private func columnHeader(_ title: String) -> some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func centered<V: View>(@ViewBuilder _ inner: () -> V) -> some View {
        VStack { Spacer(); inner(); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Graded sessions only — same rule as the Chinese DictationView: grading happens
    /// in the parent's web admin, and an ungraded session's detail would reveal word
    /// text this feature is built to keep off the kid's screen until then.
    private func loadHistory() async {
        loadingHistory = true
        defer { loadingHistory = false }
        do {
            sessions = try await api.dictationSessions(status: "graded", language: "en")
            historyError = nil
        } catch {
            historyError = error.localizedDescription
        }
    }
}
