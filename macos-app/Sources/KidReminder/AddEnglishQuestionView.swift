import SwiftUI

/// "添加错题" — lets the kid (or a parent using the kid's device) log a new
/// mistake straight from the app, without going back to edit any files. Saves
/// to the same shared bank the web admin's CRUD manages.
struct AddEnglishQuestionView: View {
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    var onSaved: () -> Void = {}

    @State private var type: EnglishQuestionType = .fillBlank
    @State private var topic = ""
    @State private var prompt = ""
    @State private var options: [String] = ["", "", "", ""]
    @State private var correctAnswer = ""
    @State private var explanation = ""
    @State private var needsAudio = false
    @State private var saving = false
    @State private var error: String?

    private var api: APIClient { APIClient(settings: settings) }

    var body: some View {
        Form {
            Section("题目") {
                Picker("题型", selection: $type) {
                    Text("填空 / 拼写").tag(EnglishQuestionType.fillBlank)
                    Text("选择题").tag(EnglishQuestionType.mcq)
                    Text("句子转换").tag(EnglishQuestionType.sentenceTransform)
                }
                TextField("分类（选填）", text: $topic)
                TextField("题目（用 ___ 表示空格）", text: $prompt, axis: .vertical)
                    .lineLimit(3...6)
            }
            if type == .mcq {
                Section("选项") {
                    ForEach(0..<4, id: \.self) { i in
                        TextField("选项 \(["A", "B", "C", "D"][i])", text: $options[i])
                    }
                }
            }
            Section("答案") {
                TextField("正确答案（多个都算对用 / 分开）", text: $correctAnswer)
                TextField("解析（选填）", text: $explanation, axis: .vertical)
                    .lineLimit(2...5)
                if type == .fillBlank {
                    Toggle("🔊 加朗读按钮（适合拼写题）", isOn: $needsAudio)
                }
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("➕ 添加错题")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .disabled(saving || prompt.trimmingCharacters(in: .whitespaces).isEmpty
                              || correctAnswer.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .frame(minWidth: 420, minHeight: 420)
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            let opts: [String]?
            if type == .mcq {
                let filled = options.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                guard filled.count >= 2 else { error = "选择题至少需要2个选项"; return }
                opts = filled
            } else {
                opts = nil
            }
            try await api.addEnglishQuestion(
                type: type, topic: topic.trimmingCharacters(in: .whitespaces),
                prompt: prompt.trimmingCharacters(in: .whitespaces), options: opts,
                correctAnswer: correctAnswer.trimmingCharacters(in: .whitespaces),
                explanation: explanation.trimmingCharacters(in: .whitespaces), needsAudio: needsAudio)
            onSaved()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
