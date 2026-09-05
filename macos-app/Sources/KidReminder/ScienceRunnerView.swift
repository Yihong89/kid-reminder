import SwiftUI

/// Where a science practice set gets its questions from. Both a paper's ▶️ and
/// the 错题本 button open the *same* window (`ScienceRunnerView`) — this is the
/// only thing that differs between them.
enum ScienceSource: Identifiable, Equatable {
    /// One full exam paper, in the paper's own question order.
    case paper(key: String, title: String)
    /// The 错题本 pool, shuffled. Membership is sticky (a parent's explicit
    /// action in the web admin is the only way out), so this mode always has
    /// something to offer once the button is enabled at all.
    case mistakes

    var id: String {
        switch self {
        case .paper(let key, _): return "paper-\(key)"
        case .mistakes: return "mistakes"
        }
    }

    var title: String {
        switch self {
        case .paper(_, let title): return title
        case .mistakes: return "📕 错题本"
        }
    }
}

/// 🔬 The one science practice window. PSLE awards one mark per distinct
/// scoring point, so feedback here is per mark point and names *which*
/// technique was missed — not just right/wrong.
///
/// The verdict shown is provisional: a parent confirms it in the web admin
/// (家长都是在网页端批改) before it counts for anything. There is no in-app
/// review — completing a set just hands it to that queue.
struct ScienceRunnerView: View {
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    let source: ScienceSource

    private enum Phase: Equatable {
        case loading
        case running(index: Int)
        case finishing
        case done(auto: Int, total: Int)
        case error(String)
    }
    private enum ItemPhase: Equatable {
        case answering
        case graded(ScienceSubmitResult)
    }

    @State private var phase: Phase = .loading
    @State private var itemPhase: ItemPhase = .answering
    @State private var session: ScienceSession?
    @State private var typed = ""
    @State private var autoSoFar = 0
    @State private var marksSoFar = 0

    private var api: APIClient { APIClient(settings: settings) }

    var body: some View {
        content
            .navigationTitle(source.title)
            // Load-bearing: on macOS a sheet sizes to its content's fitting
            // size, and short content renders small enough to look blank. See
            // DictationView's sheet comment for the full story.
            .frame(minWidth: 760, minHeight: 560)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .task { await start() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading: ProgressView("正在准备…")
        case .running(let i): runningView(index: i)
        case .finishing: ProgressView("正在提交…")
        case .done(let auto, let total): doneView(auto: auto, total: total)
        case .error(let m):
            ContentUnavailableView("出错了", systemImage: "exclamationmark.triangle",
                description: Text(m))
                .padding()
        }
    }

    // MARK: - running

    /// Two columns: the question and the answer box on the left, the scanned
    /// figure alone on the right. Splitting them is what makes the answer box
    /// usable — the kid can read the diagram and write at the same time
    /// without scrolling between them.
    ///
    /// It also avoids the crash the first version of this screen shipped with.
    /// Everything used to live in one ScrollView, so the answer box's height
    /// and the scroll content height each depended on the other; AppKit
    /// recursed through `_informContainerThatSubviewsNeedUpdateConstraints`
    /// until `-[NSWindow _postWindowNeedsUpdateConstraints]` threw. Now every
    /// vertical extent below is definite: the columns take their height from
    /// the window, the question block is capped, and the answer box fills
    /// what is left.
    @ViewBuilder
    private func runningView(index: Int) -> some View {
        let items = session?.items ?? []
        if items.indices.contains(index) {
            questionView(item: items[index], index: index, total: items.count)
        } else {
            ProgressView()
        }
    }

    private func questionView(item: ScienceSessionItem, index: Int, total: Int) -> some View {
        HStack(alignment: .top, spacing: 0) {
            answerColumn(item: item, index: index, total: total)
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)

            if let url = api.scienceImageURL(item.image) {
                Divider()
                imageColumn(url: url)
                    .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Resets the answer box when moving to a new question, so the previous
        // answer never carries over into the next one.
        .task(id: index) { itemPhase = .answering; typed = "" }
    }

    private func answerColumn(item: ScienceSessionItem, index: Int, total: Int) -> some View {
        let isLast = index >= total - 1
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("第 \(index + 1) 题 / 共 \(total) 题").font(.headline)
                Spacer()
                Text("\(item.theme) · \(item.marks) 分")
                    .font(.caption).foregroundStyle(.secondary)
            }

            // Capped rather than free-growing: this is what leaves a
            // predictable amount of room for the answer box below.
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if !item.context.isEmpty {
                        Text(item.context).font(.callout).foregroundStyle(.secondary)
                    }
                    Text(item.prompt).font(.body)
                    Text("这题 \(item.marks) 分 —— 要写出 \(item.marks) 个得分点。")
                        .font(.caption).foregroundStyle(.orange)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)

            Divider()

            switch itemPhase {
            case .answering:
                TextEditor(text: $typed)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color.primary.opacity(0.04))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    // Fills the remaining height, so a long answer stays fully
                    // visible instead of scrolling inside a short box.
                    .frame(minHeight: 160, maxHeight: .infinity)
                    .overlay(alignment: .topLeading) {
                        if typed.isEmpty {
                            Text("把答案写在这里…")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 14)
                                .allowsHitTesting(false)
                        }
                    }
                HStack {
                    Text("⌘↵ 提交").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("提交") { Task { await submit(item: item) } }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            case .graded(let result):
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("你写的").font(.caption).bold().foregroundStyle(.secondary)
                        Text(typed)
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(Color.primary.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        resultPanel(result)
                    }
                }
                .frame(maxHeight: .infinity)
                HStack {
                    Spacer()
                    Button(isLast ? "✅ 完成" : "➡️ 下一题") {
                        if isLast { Task { await finish() } } else { advance(to: index + 1) }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(14)
    }

    /// The scan on its own, scrollable — the crops are tall (~1000x1400) and
    /// the scan is authoritative over the transcribed prompt, which can carry
    /// transcription slips.
    private func imageColumn(url: URL) -> some View {
        ScrollView {
            AsyncImage(url: url) { img in
                img.resizable().scaledToFit()
            } placeholder: {
                ProgressView().frame(height: 160)
            }
            .frame(maxWidth: .infinity)
            .padding(10)
        }
    }

    /// Per-mark-point feedback. A missed point is labelled by KIND, so the
    /// message is "you didn't explain the mechanism", not merely "wrong".
    private func resultPanel(_ r: ScienceSubmitResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("自动判分：\(r.autoScore)/\(r.marks)")
                    .font(.headline)
                    .foregroundStyle(r.autoScore == r.marks ? .green : .primary)
                if r.provisional {
                    Text("（等家长在网页端批改）").font(.caption).foregroundStyle(.secondary)
                }
            }

            ForEach(r.points) { p in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: p.autoHit ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(p.autoHit ? .green : .red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.pointKind.label)
                            .font(.caption).bold()
                            .foregroundStyle(p.autoHit ? .green : .red)
                        Text(p.description).font(.callout)
                    }
                }
            }

            if !r.modelAnswer.isEmpty {
                Divider()
                Text("参考答案").font(.caption).bold().foregroundStyle(.secondary)
                Text(r.modelAnswer).font(.callout).foregroundStyle(.secondary)
            }

            if !r.doNotAccept.isEmpty {
                Divider()
                Text("不能这样答").font(.caption).bold().foregroundStyle(.orange)
                ForEach(r.doNotAccept, id: \.answer) { d in
                    VStack(alignment: .leading, spacing: 1) {
                        Text("✗ \(d.answer)").font(.callout)
                        Text(d.reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func doneView(auto: Int, total: Int) -> some View {
        VStack(spacing: 16) {
            Text("🎉").font(.system(size: 56))
            Text("做完啦！").font(.title2).bold()
            Text("自动判分 \(auto)/\(total)。\n已经交给家长在网页端批改，批改后分数才算数。")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("关闭") { dismiss() }.buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - actions

    private func start() async {
        phase = .loading
        autoSoFar = 0; marksSoFar = 0
        do {
            let s: ScienceSession
            switch source {
            case .paper(let key, _):
                s = try await api.startScienceSession(paper: key)
            case .mistakes:
                s = try await api.startScienceSession(mistakes: true)
            }
            guard !s.items.isEmpty else { phase = .error("这里还没有题目。"); return }
            session = s
            itemPhase = .answering
            typed = ""
            phase = .running(index: 0)
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    private func submit(item: ScienceSessionItem) async {
        guard let sessionId = session?.sessionId else { return }
        do {
            let r = try await api.submitScienceAnswer(sessionId: sessionId, itemId: item.itemId, answer: typed)
            autoSoFar += r.autoScore
            marksSoFar += r.marks
            itemPhase = .graded(r)
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    private func advance(to index: Int) {
        itemPhase = .answering
        typed = ""
        phase = .running(index: index)
    }

    private func finish() async {
        guard let sessionId = session?.sessionId else { return }
        phase = .finishing
        do {
            try await api.completeScienceSession(sessionId: sessionId)
            phase = .done(auto: autoSoFar, total: marksSoFar)
        } catch {
            phase = .error(error.localizedDescription)
        }
    }
}
