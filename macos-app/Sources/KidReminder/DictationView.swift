import SwiftUI

/// 📝 听写 (dictation) — the browser screen. Two columns: the kid's graded results on
/// the left, their 自定义听写表 on the right. Actually *doing* a dictation always happens
/// in `DictationRunnerView`, presented as a sheet — 随机听写 and every list's ▶️ button
/// open that same window, differing only in `DictationSource`.
struct DictationView: View {
    @EnvironmentObject var settings: SettingsStore

    @State private var customLists: [DictationList] = []
    @State private var sessions: [DictationSessionSummary] = []
    @State private var historyError: String?
    @State private var loadingHistory = true

    // A single sheet destination instead of one @State + one .sheet modifier per
    // destination — stacking multiple .sheet modifiers on one view is a known SwiftUI
    // flakiness source (can silently present a blank sheet instead of the intended
    // content); one .sheet(item:) driven by this enum sidesteps the whole class of bug.
    private enum SheetDestination: Identifiable {
        case run(DictationSource)
        case sessionDetail(Int)
        case createList
        case editList(DictationList)

        var id: String {
            switch self {
            case .run(let source): return "run-\(source.id)"
            case .sessionDetail(let id): return "session-\(id)"
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .sheet(item: $activeSheet) { sheet in
                sheetContent(for: sheet)
                    .onAppear { DevLog.log("DictationView sheet presented: \(sheet.id)") }
            }
    }

    @ViewBuilder
    private func sheetContent(for sheet: SheetDestination) -> some View {
        switch sheet {
        case .run(let source):
            NavigationStack { DictationRunnerView(source: source) }
        case .sessionDetail(let id):
            NavigationStack { DictationSessionDetailView(sessionId: id) }
        case .createList:
            NavigationStack { DictationListEditorView(onSaved: { Task { await loadCustomLists() } }) }
        case .editList(let list):
            NavigationStack { DictationListEditorView(existingList: list, onSaved: { Task { await loadCustomLists() } }) }
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
                HStack(spacing: 0) {
                    historyColumn
                    Divider()
                    listsColumn
                }
            }
            .task { await loadAll() }
        }
    }

    // MARK: - header

    private var header: some View {
        HStack(spacing: 14) {
            Text("📝").font(.system(size: 34))
            VStack(alignment: .leading, spacing: 2) {
                Text("听写").font(.title3.bold())
                Text("会挑 30 个最需要练习的词，App 念出来，写在纸上就好。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("🎲 随机听写") { activeSheet = .run(.random) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - 听写记录 column

    private var historyColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            columnHeader("📋 听写记录", trailing: nil)
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

    // MARK: - 自定义听写表 column

    private var listsColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            columnHeader("📚 自定义听写表", trailing: AnyView(
                Button { activeSheet = .createList } label: {
                    Label("新建听写表", systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("新建自定义听写表")
            ))
            if customLists.isEmpty {
                centered {
                    ContentUnavailableView("还没有自定义听写表", systemImage: "text.badge.plus",
                        description: Text("点右上角的 ＋ 新建一张，想练什么就写什么。"))
                }
            } else {
                List(customLists) { list in
                    listRow(list)
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// ▶️ is the only inline control — the column is only ~300pt wide at the usual window
    /// size. Clicking anywhere else on the row opens the editor, so 管理 needs no button.
    private func listRow(_ list: DictationList) -> some View {
        HStack(spacing: 10) {
            // The tap target is scoped to just this leading half rather than the whole
            // row, so it can't compete with ▶️'s own click handling.
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(list.name).font(.subheadline)
                    Text("\(list.itemCount ?? 0) 条").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            // Rectangle, not the content's own shape — otherwise the empty space to the
            // right of a short name wouldn't be clickable.
            .contentShape(Rectangle())
            .onTapGesture { activeSheet = .editList(list) }
            .help("点一下管理这张表")

            // The play button the whole redesign hangs on — same window as 随机听写.
            Button { activeSheet = .run(.list(list)) } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .help("开始听写这张表")
        }
        .padding(.vertical, 2)
    }

    // MARK: - shared column chrome

    private func columnHeader(_ title: String, trailing: AnyView?) -> some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            if let trailing { trailing }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func centered<V: View>(@ViewBuilder _ inner: () -> V) -> some View {
        VStack { Spacer(); inner(); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - loading

    private func loadAll() async {
        await loadCustomLists()
        await loadHistory()
    }

    private func loadCustomLists() async {
        customLists = (try? await api.dictationLists()) ?? []
    }

    /// Graded sessions only: 待批改 / 未完成 sets are deliberately not shown in the kid's
    /// app — grading happens in the parent's web admin, and an ungraded session's detail
    /// would reveal the word text this whole feature is built to keep off the screen.
    private func loadHistory() async {
        loadingHistory = true
        defer { loadingHistory = false }
        do {
            sessions = try await api.dictationSessions(status: "graded")
            historyError = nil
            DevLog.log("DictationView history loaded: \(sessions.count) graded sessions")
        } catch {
            historyError = error.localizedDescription
            DevLog.log("DictationView history load FAILED: \(error)")
        }
    }
}
