import SwiftUI

/// 📘 The English Paper 2 practice window. Items are grouped into "steps":
///   - a single mcq/oeq/ungrouped fill_blank item is its own step (unchanged
///     behaviour: tappable options or a text field, instant right/wrong,
///     oeq shows only "submitted").
///   - a run of consecutive items sharing one of the four shared-passage
///     sections (cloze_wordbank / editing / cloze_open / comprehension_oeq)
///     becomes ONE step: the full passage (and word bank, if any) is shown
///     once on the right, and the kid answers every question on the left
///     before a single 提交 submits the whole passage at once — a text field
///     per blank for the cloze tiers, a bounded text editor per question for
///     comprehension_oeq. Grouping only applies in "paper" mode — the
///     mistake bank shuffles items, so grouping there would weld together
///     unrelated leftovers from different papers.
struct EnglishPaperRunnerView: View {
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.dismissWindow) private var dismissWindow
    let source: EpaperSource

    private enum Phase: Equatable {
        case loading
        case running(step: Int)
        case finishing
        case done
        case error(String)
    }
    private enum StepPhase: Equatable {
        case answering
        case graded([EpaperSubmitResult])
    }

    // Sections that share ONE continuous passage across a run of consecutive
    // questions (see docs/superpowers/specs/2026-09-06-english-paper-practice-design.md).
    private static let groupableSections: Set<String> = ["cloze_wordbank", "editing", "cloze_open", "comprehension_oeq"]

    @State private var phase: Phase = .loading
    @State private var stepPhase: StepPhase = .answering
    @State private var session: EpaperSession?
    @State private var typed = ""                       // single-item fill_blank/oeq
    @State private var pickedOption: String?             // single-item mcq
    @State private var groupAnswers: [Int: String] = [:]  // itemId -> answer, group steps

    private var api: APIClient { APIClient(settings: settings) }

    /// Items chunked into steps. Grouping is disabled outside "paper" mode.
    private var steps: [[EpaperSessionItem]] {
        let items = session?.items ?? []
        guard session?.mode == "paper" else { return items.map { [$0] } }
        var result: [[EpaperSessionItem]] = []
        var i = 0
        while i < items.count {
            let section = items[i].section
            if Self.groupableSections.contains(section) {
                var j = i + 1
                while j < items.count && items[j].section == section { j += 1 }
                result.append(Array(items[i..<j]))
                i = j
            } else {
                result.append([items[i]])
                i += 1
            }
        }
        return result
    }

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
        case .running(let step): runningView(step: step)
        case .finishing: ProgressView("正在提交…")
        case .done: doneView()
        case .error(let m):
            ContentUnavailableView("出错了", systemImage: "exclamationmark.triangle",
                description: Text(m))
                .padding()
        }
    }

    @ViewBuilder
    private func runningView(step: Int) -> some View {
        let allSteps = steps
        if allSteps.indices.contains(step) {
            stepView(items: allSteps[step], stepIndex: step, totalSteps: allSteps.count)
        } else {
            ProgressView()
        }
    }

    private func stepView(items: [EpaperSessionItem], stepIndex: Int, totalSteps: Int) -> some View {
        let isGroup = items.count > 1
        return HStack(alignment: .top, spacing: 0) {
            answerColumn(items: items, stepIndex: stepIndex, totalSteps: totalSteps)
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)

            if isGroup {
                Divider()
                // comprehension_oeq shows the paper's FULL article (the `passage`
                // field, duplicated across the run); cloze/editing show the shared
                // passage text in `context`. Prefer `passage` when present.
                let readingText = items.compactMap { $0.passage?.isEmpty == false ? $0.passage : nil }
                                  .first ?? items.first?.context ?? ""
                passageColumn(text: readingText)
                    .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            } else if let url = api.epaperImageURL(items[0].image) {
                Divider()
                imageColumn(url: url)
                    .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: stepIndex) {
            stepPhase = .answering
            typed = ""
            pickedOption = nil
            groupAnswers = [:]
        }
    }

    private func answerColumn(items: [EpaperSessionItem], stepIndex: Int, totalSteps: Int) -> some View {
        let isLast = stepIndex >= totalSteps - 1
        let isGroup = items.count > 1
        let seqLabel = isGroup ? "第 \(items.first!.seq)–\(items.last!.seq) 题" : "第 \(items[0].seq) 题"
        let totalMarks = items.reduce(0) { $0 + $1.marks }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(seqLabel) / 共 \(session?.items.count ?? 0) 题").font(.headline)
                Spacer()
                Text("\(totalMarks) 分").font(.caption).foregroundStyle(.secondary)
            }

            if !isGroup {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if !items[0].context.isEmpty {
                            Text(items[0].context).font(.callout).foregroundStyle(.secondary)
                        }
                        Text(items[0].prompt).font(.body)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)
            }

            Divider()

            switch stepPhase {
            case .answering: answeringControl(items: items)
            case .graded(let results): gradedPanel(items: items, results: results, isLast: isLast, stepIndex: stepIndex)
            }
        }
        .padding(14)
    }

    @ViewBuilder
    private func answeringControl(items: [EpaperSessionItem]) -> some View {
        if items.count > 1 {
            groupAnsweringControl(items: items)
        } else {
            singleAnsweringControl(item: items[0])
        }
    }

    /// One text field per blank, labelled with its printed question number, plus
    /// one 提交 that grades every blank in the passage at once.
    private func groupAnsweringControl(items: [EpaperSessionItem]) -> some View {
        let allFilled = items.allSatisfy {
            !(groupAnswers[$0.itemId] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .top) {
                                Text("(\(item.seq))").font(.body).bold().frame(width: 36, alignment: .leading)
                                Text(item.prompt).font(.callout).foregroundStyle(.secondary)
                            }
                            if item.questionType == "oeq" {
                                groupOeqAnswerBox(item)
                            } else {
                                TextField("填空…", text: groupAnswerBinding(item.itemId))
                                    .textFieldStyle(.roundedBorder)
                                    .font(.body)
                                    .padding(.leading, 40)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("提交") { Task { await submit(items: items, answers: groupAnswers) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!allFilled)
            }
        }
    }

    private func groupAnswerBinding(_ itemId: Int) -> Binding<String> {
        Binding(get: { groupAnswers[itemId] ?? "" }, set: { groupAnswers[itemId] = $0 })
    }

    /// A comprehension_oeq question inside a shared-passage group needs room
    /// for a real sentence, not a single-line field — same bounded TextEditor
    /// as the standalone oeq case, just sized down to fit inside the list.
    private func groupOeqAnswerBox(_ item: EpaperSessionItem) -> some View {
        TextEditor(text: groupAnswerBinding(item.itemId))
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(6)
            .background(Color.primary.opacity(0.04))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .frame(height: 70)
            .padding(.leading, 40)
    }

    @ViewBuilder
    private func singleAnsweringControl(item: EpaperSessionItem) -> some View {
        switch item.questionType {
        case "mcq":
            VStack(alignment: .leading, spacing: 8) {
                ForEach(item.options ?? [], id: \.self) { opt in
                    Button {
                        pickedOption = opt
                        Task { await submit(items: [item], answers: [item.itemId: opt]) }
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
                    .onSubmit { Task { await submit(items: [item], answers: [item.itemId: typed]) } }
                Button("提交") { Task { await submit(items: [item], answers: [item.itemId: typed]) } }
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
                Button("提交") { Task { await submit(items: [item], answers: [item.itemId: typed]) } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    @ViewBuilder
    private func gradedPanel(items: [EpaperSessionItem], results: [EpaperSubmitResult], isLast: Bool, stepIndex: Int) -> some View {
        let isGroup = items.count > 1
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(zip(items, results)), id: \.0.itemId) { item, result in
                    VStack(alignment: .leading, spacing: 8) {
                        if isGroup {
                            Text("(\(item.seq))").font(.callout).bold().foregroundStyle(.secondary)
                        }
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
            }
        }
        .frame(maxHeight: .infinity)
        HStack {
            Spacer()
            Button(isLast ? "✅ 完成" : "➡️ 下一题") {
                if isLast { Task { await finish() } } else { advance(to: stepIndex + 1) }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }

    private func passageColumn(text: String) -> some View {
        ScrollView {
            Text(text)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
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
            stepPhase = .answering
            typed = ""
            groupAnswers = [:]
            phase = .running(step: 0)
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    /// Submits every item in the step (one call each — no batch endpoint), in
    /// order, collecting one result per item before revealing feedback.
    private func submit(items: [EpaperSessionItem], answers: [Int: String]) async {
        guard let sessionId = session?.sessionId else { return }
        var results: [EpaperSubmitResult] = []
        do {
            for item in items {
                let answer = answers[item.itemId] ?? ""
                guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                let r = try await api.submitEpaperAnswer(sessionId: sessionId, itemId: item.itemId, answer: answer)
                results.append(r)
            }
            stepPhase = .graded(results)
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    private func advance(to step: Int) {
        stepPhase = .answering
        typed = ""
        pickedOption = nil
        groupAnswers = [:]
        phase = .running(step: step)
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
