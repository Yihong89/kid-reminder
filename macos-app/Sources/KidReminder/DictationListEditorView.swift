import SwiftUI

/// Create or manage one 自定义听写表 (freeform text list). Both the parent (web admin)
/// and the kid (here) can create/add/edit/delete — this is explicitly self-managed
/// content, unlike the graded vocab/English banks. No word/sentence split: each entry
/// is just whatever text should be read aloud — a word, a phrase, or a whole sentence.
struct DictationListEditorView: View {
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    /// Called whenever something changes (list created/renamed/deleted, item added/
    /// edited/deleted) so the presenting view can refresh its own list of lists.
    var onSaved: () -> Void = {}

    @State private var listId: Int?
    @State private var name: String
    @State private var items: [DictationListItem] = []
    @State private var newText = ""
    @State private var editingItemId: Int?
    @State private var busy = false
    @State private var error: String?

    private var api: APIClient { APIClient(settings: settings) }
    private var isNew: Bool { listId == nil }

    init(existingList: DictationList? = nil, onSaved: @escaping () -> Void = {}) {
        self._listId = State(initialValue: existingList?.id)
        self._name = State(initialValue: existingList?.name ?? "")
        self.onSaved = onSaved
    }

    var body: some View {
        Form {
            Section("表名") {
                if isNew {
                    TextField("比如「本周听写」", text: $name)
                    Button("创建") { Task { await createList() } }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                } else {
                    HStack {
                        TextField("表名", text: $name)
                        Button("保存改名") { Task { await saveName() } }
                            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                    }
                }
            }

            if let listId {
                Section("内容（\(items.count) 条）") {
                    if items.isEmpty {
                        Text("还没有内容，在下面加一条吧。").foregroundStyle(.secondary)
                    }
                    ForEach(items) { item in
                        HStack {
                            Text(item.text)
                            Spacer()
                            Button { startEdit(item) } label: { Image(systemName: "pencil") }
                                .buttonStyle(.plain)
                        }
                    }
                    .onDelete { offsets in Task { await deleteItems(at: offsets, listId: listId) } }
                }

                Section(editingItemId == nil ? "添加内容" : "编辑内容") {
                    TextField("一个字、一个词、一句话都可以", text: $newText, axis: .vertical)
                        .lineLimit(2...4)
                    HStack {
                        Button(editingItemId == nil ? "➕ 加入" : "💾 保存修改") {
                            Task { await saveItem(listId: listId) }
                        }
                        .disabled(newText.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                        if editingItemId != nil {
                            Button("取消编辑") { editingItemId = nil; newText = "" }
                        }
                    }
                }

                Section {
                    Button("🗑 删除整张表", role: .destructive) { Task { await deleteList(listId) } }
                }
            }

            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(isNew ? "➕ 新建听写表" : "管理听写表")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("关闭") { dismiss() }
            }
        }
        .task { if let listId { await loadItems(listId) } }
    }

    private func createList() async {
        busy = true; defer { busy = false }
        do {
            let id = try await api.createDictationList(name: name.trimmingCharacters(in: .whitespaces))
            listId = id
            onSaved()
        } catch { self.error = error.localizedDescription }
    }

    private func saveName() async {
        guard let listId else { return }
        busy = true; defer { busy = false }
        do {
            try await api.renameDictationList(id: listId, name: name.trimmingCharacters(in: .whitespaces))
            onSaved()
        } catch { self.error = error.localizedDescription }
    }

    private func loadItems(_ listId: Int) async {
        do {
            items = try await api.dictationListDetail(id: listId).items
        } catch { self.error = error.localizedDescription }
    }

    private func startEdit(_ item: DictationListItem) {
        editingItemId = item.id
        newText = item.text
    }

    private func saveItem(listId: Int) async {
        let text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        busy = true; defer { busy = false }
        do {
            if let editingItemId {
                try await api.updateDictationListItem(listId: listId, itemId: editingItemId, text: text)
            } else {
                try await api.addDictationListItem(listId: listId, text: text)
            }
            editingItemId = nil
            newText = ""
            await loadItems(listId)
            onSaved()
        } catch { self.error = error.localizedDescription }
    }

    private func deleteItems(at offsets: IndexSet, listId: Int) async {
        for index in offsets {
            do { try await api.deleteDictationListItem(listId: listId, itemId: items[index].id) }
            catch { self.error = error.localizedDescription }
        }
        await loadItems(listId)
        onSaved()
    }

    private func deleteList(_ listId: Int) async {
        do {
            try await api.deleteDictationList(id: listId)
            onSaved()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
