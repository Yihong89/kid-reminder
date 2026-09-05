import SwiftUI

/// 🔬 科学 — the browser screen. Lists exam papers (school + year) the kid can
/// play start to finish, plus a 错题本 entry point for the questions a parent's
/// review has flagged as missed. Playing either always lands in the same
/// window, `ScienceRunnerView`, presented as a sheet — mirrors 听写's
/// DictationView/DictationRunnerView split.
///
/// Grading lives in the web admin now (家长都是在网页端完成的), not here — this
/// screen has no review affordance at all, only practice.
struct SciencePracticeView: View {
    @EnvironmentObject var settings: SettingsStore

    @State private var papers: [SciencePaper] = []
    @State private var mistakeCount = 0
    @State private var loading = true
    @State private var loadError: String?

    // Single sheet destination + Identifiable enum — same reasoning as
    // DictationView: stacking multiple .sheet modifiers on one view is a known
    // source of a sheet silently rendering blank.
    private enum SheetDestination: Identifiable {
        case run(ScienceSource)
        var id: String {
            switch self {
            case .run(let source): return "run-\(source.id)"
            }
        }
    }
    @State private var activeSheet: SheetDestination?

    private var api: APIClient { APIClient(settings: settings) }

    var body: some View {
        content
            .navigationTitle("科学")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .run(let source):
                    NavigationStack { ScienceRunnerView(source: source) }
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
            VStack(spacing: 0) {
                header
                Divider()
                body_
            }
            .task { await load() }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Text("🔬").font(.system(size: 34))
            VStack(alignment: .leading, spacing: 2) {
                Text("科学").font(.title3.bold())
                Text("挑一张卷子完整做完，或者复习错题本。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            // Sticky pool — only ever shrinks via a parent's explicit action in
            // the web admin, never automatically, so this button staying enabled
            // across sessions is expected, not a bug.
            Button {
                activeSheet = .run(.mistakes)
            } label: {
                Label(mistakeCount > 0 ? "📕 错题本 (\(mistakeCount))" : "📕 错题本",
                      systemImage: "book.closed.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(mistakeCount == 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var body_: some View {
        if loading {
            centered { ProgressView() }
        } else if let loadError {
            centered {
                ContentUnavailableView("加载失败", systemImage: "exclamationmark.triangle",
                    description: Text(loadError))
            }
        } else if papers.isEmpty {
            centered {
                ContentUnavailableView("还没有卷子", systemImage: "doc.text",
                    description: Text("家长还没有导入科学卷子。"))
            }
        } else {
            List(papers) { paper in paperRow(paper) }
                .listStyle(.inset)
        }
    }

    private func paperRow(_ paper: SciencePaper) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(paper.school) \(paper.year.map(String.init) ?? "")")
                    .font(.subheadline)
                Text("\(paper.questionCount) 题 · \(paper.marksTotal) 分")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                activeSheet = .run(.paper(key: paper.paperKey, title: "\(paper.school) \(paper.year.map(String.init) ?? "")"))
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .help("完整做这张卷子")
        }
        .padding(.vertical, 2)
    }

    private func centered<V: View>(@ViewBuilder _ inner: () -> V) -> some View {
        VStack { Spacer(); inner(); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let r = try await api.sciencePapers()
            papers = r.papers
            mistakeCount = r.mistakeCount
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}
