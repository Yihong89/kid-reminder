import SwiftUI

/// 📖 English wrong-answer practice: a mixed set of fill-in-the-blank/spelling,
/// multiple-choice, and sentence-transformation questions pulled from the kid's
/// own mistake log. Unlike 听写, everything is typed/tapped in the app and
/// auto-graded immediately — no parent grading step needed.
struct EnglishPracticeView: View {
    @EnvironmentObject var settings: SettingsStore
    @StateObject private var player = DictationAudioPlayer()

    private enum ItemPhase: Equatable {
        case answering
        case graded(EnglishAnswerResult)
    }

    private enum Phase: Equatable {
        case idle
        case starting
        case running(index: Int)
        case finishing
        case done(correct: Int, total: Int)
        case error(String)
    }

    @State private var phase: Phase = .idle
    @State private var session: EnglishSession?
    @State private var itemPhase: ItemPhase = .answering
    @State private var typedAnswer = ""
    @State private var showAddSheet = false
    @State private var correctSoFar = 0

    private var api: APIClient { APIClient(settings: settings) }

    var body: some View {
        content
            .navigationTitle("英语错题练习")
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .sheet(isPresented: $showAddSheet) {
                NavigationStack { AddEnglishQuestionView() }
            }
    }

    @ViewBuilder
    private var content: some View {
        if settings.host.isEmpty || settings.pin.isEmpty {
            ContentUnavailableView("Not connected",
                systemImage: "antenna.radiowaves.left.and.right.slash",
                description: Text("Enter the server address and PIN in Settings."))
        } else {
            switch phase {
            case .idle: idleView
            case .starting: ProgressView("正在生成练习题…")
            case .running(let index): runningView(index: index)
            case .finishing: ProgressView("正在提交…")
            case .done(let correct, let total): doneView(correct: correct, total: total)
            case .error(let message): errorView(message)
            }
        }
    }

    private var idleView: some View {
        VStack(spacing: 16) {
            Text("📖").font(.system(size: 56))
            Text("来做10道错题练习吧").font(.title2).bold()
            Text("会从做错最多的题里随机抽10道，选择题直接选，填空/转换题打字回答，交了马上告诉你对不对。")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button("🚀 开始练习") { Task { await start() } }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            Button("➕ 添加一道错题") { showAddSheet = true }
                .buttonStyle(.bordered)
        }
    }

    private func runningView(index: Int) -> some View {
        let total = session?.items.count ?? 0
        let item = session?.items[index]
        let isLast = index >= total - 1

        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("第 \(index + 1) 题 / 共 \(total) 题").font(.headline)
                    Spacer()
                    if let item, !item.topic.isEmpty {
                        Text(item.topic).font(.caption).foregroundStyle(.secondary)
                    }
                }

                if let item {
                    HStack(alignment: .top, spacing: 8) {
                        markdownText(item.prompt).font(.title3)
                        if item.needsAudio {
                            Button {
                                if let url = api.englishAudioURL(questionId: item.questionId) { player.play(url: url) }
                            } label: {
                                Image(systemName: player.isLoading ? "hourglass" : "speaker.wave.2.fill")
                            }
                            .disabled(player.isBusy)
                            .help("朗读完整句子")
                        }
                    }

                    answerArea(item: item)

                    if case .graded(let result) = itemPhase {
                        feedbackView(result: result, item: item)
                    }
                }

                HStack {
                    Spacer()
                    if case .answering = itemPhase {
                        Button("提交") { Task { await submit(item: item!) } }
                            .buttonStyle(.borderedProminent)
                            .disabled(!canSubmit(item: item))
                    } else {
                        Button(isLast ? "✅ 完成练习" : "➡️ 下一题") {
                            if isLast { Task { await finish() } } else { advance(to: index + 1) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .task(id: index) { typedAnswer = ""; itemPhase = .answering }
    }

    @ViewBuilder
    private func answerArea(item: EnglishSessionItem) -> some View {
        switch item.type {
        case .mcq:
            VStack(alignment: .leading, spacing: 8) {
                ForEach(item.options ?? [], id: \.self) { opt in
                    Button {
                        typedAnswer = opt
                        Task { await submit(item: item) }
                    } label: {
                        HStack {
                            Text(opt)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.bordered)
                    .disabled(itemPhase != .answering)
                }
            }
        case .fillBlank, .sentenceTransform:
            TextField(item.type == .fillBlank ? "打字填空…" : "改写整句…", text: $typedAnswer, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .disabled(itemPhase != .answering)
                .onSubmit { Task { await submit(item: item) } }
        }
    }

    private func feedbackView(result: EnglishAnswerResult, item: EnglishSessionItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(result.correct ? "答对了！" : "答错了", systemImage: result.correct ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(result.correct ? .green : .red)
                .font(.headline)
            if !result.correct {
                Text("正确答案：\(result.correctAnswer)").font(.subheadline)
            }
            if !result.explanation.isEmpty {
                markdownText(result.explanation).font(.callout).foregroundStyle(.secondary)
            }
            if item.type == .sentenceTransform && !result.correct {
                Button("我写的其实也对，改判 ✓") { Task { await override(item: item, correct: true) } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func markdownText(_ s: String) -> Text {
        (try? Text(AttributedString(markdown: s))) ?? Text(s)
    }

    private func canSubmit(item: EnglishSessionItem?) -> Bool {
        guard let item, item.type != .mcq else { return false } // mcq submits on tap
        return !typedAnswer.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func doneView(correct: Int, total: Int) -> some View {
        VStack(spacing: 16) {
            Text("🎉").font(.system(size: 56))
            Text("练习完成！答对 \(correct) / \(total) 题").font(.title2).bold()
            Button("再来一组") { reset() }
                .buttonStyle(.bordered)
        }
    }

    private func errorView(_ message: String) -> some View {
        ContentUnavailableView("出错了", systemImage: "exclamationmark.triangle",
            description: Text(message))
            .overlay(alignment: .bottom) {
                Button("重试") { reset() }.buttonStyle(.bordered).padding(.bottom, 40)
            }
    }

    // MARK: - actions

    private func start() async {
        phase = .starting
        correctSoFar = 0
        do {
            let s = try await api.startEnglishSession()
            guard !s.items.isEmpty else { phase = .error("错题库还是空的，先添加几道错题。"); return }
            session = s
            phase = .running(index: 0)
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    private func submit(item: EnglishSessionItem) async {
        guard let sessionId = session?.sessionId else { return }
        do {
            let result = try await api.submitEnglishAnswer(sessionId: sessionId, itemId: item.itemId, answer: typedAnswer)
            if result.correct { correctSoFar += 1 }
            itemPhase = .graded(result)
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    private func override(item: EnglishSessionItem, correct: Bool) async {
        guard let sessionId = session?.sessionId else { return }
        do {
            try await api.overrideEnglishAnswer(sessionId: sessionId, itemId: item.itemId, correct: correct)
            if correct { correctSoFar += 1 }
            if case .graded(let old) = itemPhase {
                itemPhase = .graded(EnglishAnswerResult(correct: correct, correctAnswer: old.correctAnswer, explanation: old.explanation))
            }
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    private func advance(to index: Int) {
        phase = .running(index: index)
    }

    private func finish() async {
        guard let sessionId = session?.sessionId else { return }
        phase = .finishing
        do {
            try await api.completeEnglishSession(sessionId: sessionId)
            phase = .done(correct: correctSoFar, total: session?.items.count ?? 0)
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    private func reset() {
        player.stop()
        session = nil
        phase = .idle
    }
}
