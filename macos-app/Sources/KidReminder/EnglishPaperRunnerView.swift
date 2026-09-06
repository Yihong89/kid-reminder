import SwiftUI

/// 📘 The English Paper 2 practice window. Three UI shapes share one screen,
/// picked by item.questionType:
///   mcq         -> tappable option buttons, instant right/wrong
///   fill_blank  -> single-line text field, instant right/wrong
///   oeq         -> multi-line text editor, "submitted" only (parent confirms
///                  later in the web admin) — same bounded-height TextEditor
///                  fix used in ScienceRunnerView, never TextField(axis:
///                  .vertical) in a ScrollView (that combination caused the
///                  original science-module AutoLayout crash).
struct EnglishPaperRunnerView: View {
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.dismissWindow) private var dismissWindow
    let source: EpaperSource

    private enum Phase: Equatable {
        case loading
        case running(index: Int)
        case finishing
        case done
        case error(String)
    }
    private enum ItemPhase: Equatable {
        case answering
        case graded(EpaperSubmitResult)
    }

    @State private var phase: Phase = .loading
    @State private var itemPhase: ItemPhase = .answering
    @State private var session: EpaperSession?
    @State private var typed = ""
    @State private var pickedOption: String?

    private var api: APIClient { APIClient(settings: settings) }

    var body: some View {
        content
            .navigationTitle(source.title)
            .frame(minWidth: 1000, minHeight: 740)
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button("关闭") { dismissWindow() }
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
        case .done: doneView()
        case .error(let m):
            ContentUnavailableView("出错了", systemImage: "exclamationmark.triangle",
                description: Text(m))
                .padding()
        }
    }

    @ViewBuilder
    private func runningView(index: Int) -> some View {
        let items = session?.items ?? []
        if items.indices.contains(index) {
            questionView(item: items[index], index: index, total: items.count)
        } else {
            ProgressView()
        }
    }

    private func questionView(item: EpaperSessionItem, index: Int, total: Int) -> some View {
        HStack(alignment: .top, spacing: 0) {
            answerColumn(item: item, index: index, total: total)
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)

            if let url = api.epaperImageURL(item.image) {
                Divider()
                imageColumn(url: url)
                    .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: index) { itemPhase = .answering; typed = ""; pickedOption = nil }
    }

    private func answerColumn(item: EpaperSessionItem, index: Int, total: Int) -> some View {
        let isLast = index >= total - 1
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("第 \(index + 1) 题 / 共 \(total) 题").font(.headline)
                Spacer()
                Text("\(item.marks) 分").font(.caption).foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if !item.context.isEmpty {
                        Text(item.context).font(.callout).foregroundStyle(.secondary)
                    }
                    Text(item.prompt).font(.body)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)

            Divider()

            switch itemPhase {
            case .answering: answeringControl(item: item)
            case .graded(let result): gradedPanel(item: item, result: result, isLast: isLast, index: index)
            }
        }
        .padding(14)
    }

    @ViewBuilder
    private func answeringControl(item: EpaperSessionItem) -> some View {
        switch item.questionType {
        case "mcq":
            VStack(alignment: .leading, spacing: 8) {
                ForEach(item.options ?? [], id: \.self) { opt in
                    Button {
                        pickedOption = opt
                        Task { await submit(item: item, answer: opt) }
                    } label: {
                        HStack {
                            Text(opt).font(.body)
                            Spacer()
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
        case "fill_blank":
            HStack {
                TextField("填空…", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .font(.body)
                    .onSubmit { Task { await submit(item: item, answer: typed) } }
                Button("提交") { Task { await submit(item: item, answer: typed) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        default: // "oeq"
            TextEditor(text: $typed)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color.primary.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .frame(minHeight: 160, maxHeight: .infinity)
                .overlay(alignment: .topLeading) {
                    if typed.isEmpty {
                        Text("把答案写在这里…")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11).padding(.vertical, 14)
                            .allowsHitTesting(false)
                    }
                }
            HStack {
                Text("⌘↵ 提交").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("提交") { Task { await submit(item: item, answer: typed) } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    @ViewBuilder
    private func gradedPanel(item: EpaperSessionItem, result: EpaperSubmitResult, isLast: Bool, index: Int) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if result.provisional {
                    Text("已提交，等待家长在网页端批改")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    HStack {
                        Image(systemName: (result.correct ?? false) ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle((result.correct ?? false) ? .green : .red)
                        Text((result.correct ?? false) ? "答对了" : "答错了")
                            .font(.headline)
                            .foregroundStyle((result.correct ?? false) ? .green : .red)
                    }
                    if let correctAnswer = result.correctAnswer, !(result.correct ?? true) {
                        Text("正确答案：\(correctAnswer)").font(.callout).foregroundStyle(.secondary)
                    }
                }
                if !result.explanation.isEmpty {
                    Divider()
                    Text(result.explanation).font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 10))
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

    private func doneView() -> some View {
        VStack(spacing: 16) {
            Text("🎉").font(.system(size: 56))
            Text("做完啦！").font(.title2).bold()
            Text("选择题、填空题已经批完；问答题交给家长在网页端批改。")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("关闭") { dismissWindow() }.buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - actions

    private func start() async {
        phase = .loading
        do {
            let s: EpaperSession
            switch source {
            case .paper(let key, _): s = try await api.startEpaperSession(paper: key)
            case .mistakes: s = try await api.startEpaperSession(mistakes: true)
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

    private func submit(item: EpaperSessionItem, answer: String) async {
        guard let sessionId = session?.sessionId, !answer.isEmpty else { return }
        do {
            let r = try await api.submitEpaperAnswer(sessionId: sessionId, itemId: item.itemId, answer: answer)
            itemPhase = .graded(r)
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    private func advance(to index: Int) {
        itemPhase = .answering
        typed = ""
        pickedOption = nil
        phase = .running(index: index)
    }

    private func finish() async {
        guard let sessionId = session?.sessionId else { return }
        phase = .finishing
        do {
            try await api.completeEpaperSession(sessionId: sessionId)
            phase = .done
        } catch {
            phase = .error(error.localizedDescription)
        }
    }
}
