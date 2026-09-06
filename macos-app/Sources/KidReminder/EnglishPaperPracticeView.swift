import SwiftUI

/// 📘 英语试卷 — the browser screen. Lists exam papers (school + year) the kid
/// can play start to finish, plus a 错题本 entry point. Mirrors
/// SciencePracticeView exactly, including opening the runner as its own
/// top-level window (via openWindow) rather than a sheet, for a real
/// maximize/zoom-capable title bar.
struct EnglishPaperPracticeView: View {
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.openWindow) private var openWindow

    @State private var papers: [EpaperPaper] = []
    @State private var mistakeCount = 0
    @State private var loading = true
    @State private var loadError: String?

    private var api: APIClient { APIClient(settings: settings) }

    var body: some View {
        content
            .navigationTitle("英语试卷")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            Text("📘").font(.system(size: 34))
            VStack(alignment: .leading, spacing: 2) {
                Text("英语试卷").font(.title3.bold())
                Text("挑一张卷子完整做完，或者复习错题本。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                openWindow(id: "epaper-runner", value: EpaperSource.mistakes)
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
                    description: Text("家长还没有导入英语试卷。"))
            }
        } else {
            List(papers) { paper in paperRow(paper) }
                .listStyle(.inset)
        }
    }

    private func paperRow(_ paper: EpaperPaper) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(paper.school) \(paper.year.map(String.init) ?? "")")
                    .font(.subheadline)
                Text("\(paper.questionCount) 题 · \(paper.marksTotal) 分")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                let source = EpaperSource.paper(key: paper.paperKey, title: "\(paper.school) \(paper.year.map(String.init) ?? "")")
                openWindow(id: "epaper-runner", value: source)
            } label: {
                Label("开始", systemImage: "play.fill")
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
            let r = try await api.epaperPapers()
            papers = r.papers
            mistakeCount = r.mistakeCount
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}
