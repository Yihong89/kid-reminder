import SwiftUI

/// Word Wisely：孩子自己的生词积累本。每天阅读/作业里遇到不认识的单词，
/// 把单词 + 见到它的那句例句记进来，日积月累攒成自己的词汇库。
///
/// 录入流程为"连续记几个词"优化过：单词栏回车跳例句栏，例句栏回车保存、
/// 清空并回到单词栏，中间不用碰鼠标。保存成功播一下 Today 同款 ✓ 音效。
///
/// 单词全库唯一（后端按小写去重，重复收录返回 409，错误文案直接显示在
/// 表单下方）。列表按"遇到它的那一天"分组倒序展示；服务端 created_at
/// 用本机时区落库，所以这个 day 就是孩子真正遇到那个单词的日子。
struct WordWiselyView: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var words: [WordWiseEntry] = []
    @State private var newWord = ""
    @State private var newSentence = ""
    @State private var editingId: Int?
    @State private var search = ""
    @State private var busy = false
    @State private var error: String?
    @State private var justSaved: String?
    @State private var refreshKey = 0
    @FocusState private var focus: Field?
    private enum Field { case word, sentence }

    private var api: APIClient { APIClient(settings: settings) }

    var body: some View {
        VStack(spacing: 0) {
            addForm
                .padding(12)
            Divider()
            list
        }
        .navigationTitle("Word Wisely")
        .toolbar {
            ToolbarItemGroup {
                if busy { ProgressView().controlSize(.small) }
                Button { Task { await load() } } label: { Label("刷新", systemImage: "arrow.clockwise") }
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "搜索单词或例句")
        .task(id: refreshKey) { await load() }
        .onChange(of: settings.host) { _, _ in refreshKey += 1 }
        .onChange(of: settings.port) { _, _ in refreshKey += 1 }
        .onChange(of: settings.pin) { _, _ in refreshKey += 1 }
        .onChange(of: settings.role) { _, _ in refreshKey += 1 }
    }

    // MARK: 录入表单

    private var trimmedWord: String { newWord.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedSentence: String { newSentence.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { !trimmedWord.isEmpty && !trimmedSentence.isEmpty }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField(editingId == nil ? "不认识的单词，比如 reluctant" : "单词", text: $newWord)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .focused($focus, equals: .word)
                    .onSubmit { focus = .sentence }
                    .onChange(of: newWord) { _, _ in justSaved = nil }
                TextField("在哪句话里见到它的？", text: $newSentence)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .sentence)
                    .onSubmit { save() }
                // 不挂 keyboardShortcut：回车已经被两个输入框的 onSubmit 接管，
                // 按钮再绑 defaultAction 会一次回车存两条。
                Button(editingId == nil ? "收录 🌱" : "保存修改") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave || busy)
                if editingId != nil {
                    Button("取消") { resetForm() }
                }
            }
            if let justSaved {
                Text("✅ " + justSaved).font(.caption).foregroundStyle(.green)
            }
            if let error {
                Text("⚠️ " + error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func save() {
        guard canSave else { return }
        busy = true
        error = nil
        justSaved = nil
        Task {
            do {
                if let id = editingId {
                    try await api.updateWordWise(id: id, word: trimmedWord, sentence: trimmedSentence)
                } else {
                    try await api.addWordWise(word: trimmedWord, sentence: trimmedSentence)
                    SoundEffects.playDone(host: settings.host, port: settings.port)
                    justSaved = "已收录 “\(trimmedWord)”"
                }
                resetForm()
                await load()
                focus = .word
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }

    private func startEdit(_ entry: WordWiseEntry) {
        editingId = entry.id
        newWord = entry.word
        newSentence = entry.sentence
        error = nil
        focus = .word
    }

    private func resetForm() {
        editingId = nil
        newWord = ""
        newSentence = ""
    }

    // MARK: 累计列表

    private var filtered: [WordWiseEntry] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return words }
        return words.filter { $0.word.lowercased().contains(q) || $0.sentence.lowercased().contains(q) }
    }

    /// 按天分组（服务端已按 created_at 倒序返回，这里保持原顺序聚合）。
    private var grouped: [(day: String, items: [WordWiseEntry])] {
        var out: [(String, [WordWiseEntry])] = []
        for e in filtered {
            if out.last?.0 == e.day { out[out.count - 1].1.append(e) }
            else { out.append((e.day, [e])) }
        }
        return out
    }

    private var list: some View {
        List {
            if filtered.isEmpty {
                if words.isEmpty && search.isEmpty {
                    ContentUnavailableView("还没有积累单词",
                        systemImage: "leaf.fill",
                        description: Text("遇到不认识的单词，就在上面记下来吧 —— 每天几个，一学期就是一笔财富。"))
                } else {
                    Text("没有匹配的单词").foregroundStyle(.secondary)
                }
            }
            ForEach(grouped, id: \.day) { group in
                Section("📅 \(dayLabel(group.day)) · \(group.items.count) 个词") {
                    ForEach(group.items) { entry in row(entry) }
                }
            }
        }
    }

    private func row(_ entry: WordWiseEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.word).font(.body.weight(.semibold))
                Text(entry.sentence).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if entry.createdBy == "admin" {
                Text("家长").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                    .foregroundStyle(.secondary)
            }
            Button { startEdit(entry) } label: { Image(systemName: "pencil") }
                .buttonStyle(.borderless)
                .help("修改")
            Button { delete(entry) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("删除")
        }
        .padding(.vertical, 2)
    }

    private func delete(_ entry: WordWiseEntry) {
        busy = true
        error = nil
        Task {
            do { try await api.deleteWordWise(id: entry.id); await load() }
            catch { self.error = error.localizedDescription }
            busy = false
        }
    }

    // MARK: 日期

    /// 最近两天说"今天/昨天"，其余给可读日期。day 来自服务端本机时区的
    /// created_at，与 Calendar.current 的比较在同一台时区上，成立。
    private func dayLabel(_ day: String) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        guard let d = fmt.date(from: day) else { return day }
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "今天" }
        if cal.isDateInYesterday(d) { return "昨天" }
        fmt.dateStyle = .medium
        return fmt.string(from: d)
    }

    private func load() async {
        busy = true
        defer { busy = false }
        do {
            words = try await api.wordWiseList()
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
