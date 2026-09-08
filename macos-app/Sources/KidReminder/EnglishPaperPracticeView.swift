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
    @State private var downloadingPaperKey: String?
    @State private var toastMessage: String?

    private var api: APIClient { APIClient(settings: settings) }

    var body: some View {
        content
            .navigationTitle("英语试卷")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) { toast }
    }

    @ViewBuilder
    private var toast: some View {
        if let toastMessage {
            Text(toastMessage)
                .font(.callout)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .shadow(radius: 4)
                .padding(.bottom, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
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
                if let last = paper.lastResult {
                    let pct = last.marksTotal > 0 ? Int((Double(last.scoreEarned) / Double(last.marksTotal) * 100).rounded()) : 0
                    Text("上次成绩：\(last.scoreEarned)/\(last.marksTotal) · \(pct)%")
                        .font(.caption.bold())
                        .foregroundStyle(pct >= 90 ? .green : .orange)
                }
            }
            Spacer()
            if paper.lastResult != nil {
                Button {
                    downloadReport(for: paper)
                } label: {
                    if downloadingPaperKey == paper.paperKey {
                        ProgressView().controlSize(.small).frame(width: 16)
                    } else {
                        Label("下载错题报告", systemImage: "square.and.arrow.down")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(downloadingPaperKey != nil)
                .help("下载这次的错题分析报告（英文，孩子能看懂）")
            }
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

    /// Fetches the reviewed session's report HTML and saves it straight to
    /// ~/Downloads (no save panel — see 2026-09-08 design discussion), then
    /// shows a brief confirmation toast. Overwrites a same-named prior
    /// download for this session, which is fine: the content is identical.
    private func downloadReport(for paper: EpaperPaper) {
        guard let last = paper.lastResult else { return }
        downloadingPaperKey = paper.paperKey
        Task {
            defer { downloadingPaperKey = nil }
            do {
                let data = try await api.epaperReportHTML(sessionId: last.sessionId)
                guard let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
                    showToast("找不到 Downloads 文件夹")
                    return
                }
                let dateStamp = String(last.completedAt.prefix(10))
                let namePart = sanitizedFilename("\(paper.school)-\(paper.year.map(String.init) ?? "")")
                let url = downloadsDir.appendingPathComponent("\(namePart)-mistakes-\(dateStamp).html")
                try data.write(to: url)
                showToast("已保存到 Downloads：\(url.lastPathComponent)")
            } catch {
                showToast("下载失败：\(error.localizedDescription)")
            }
        }
    }

    private func sanitizedFilename(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics
        var result = ""
        for scalar in s.unicodeScalars {
            result.append(allowed.contains(scalar) ? Character(scalar) : "-")
        }
        while result.contains("--") { result = result.replacingOccurrences(of: "--", with: "-") }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private func showToast(_ text: String) {
        withAnimation { toastMessage = text }
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if toastMessage == text { withAnimation { toastMessage = nil } }
        }
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
