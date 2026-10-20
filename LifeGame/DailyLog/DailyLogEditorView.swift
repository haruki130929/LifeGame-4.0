import SwiftUI

struct DailyLogEditorView: View {
    enum Mode {
        case add
        case edit(DailyLogEntry)
    }

    let mode: Mode
    @ObservedObject var store: DailyLogStore
    @Environment(\.dismiss) private var dismiss

    @State private var draft = DailyLogEntry()

    private var title: String {
        switch mode {
        case .add:  return String(localized: "新增每日紀錄")
        case .edit: return String(localized: "編輯每日紀錄")
        }
    }

    var body: some View {
        DailyLogFormView(entry: $draft)
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        save()
                        dismiss()
                    }
                }
            }
            .onAppear {
                switch mode {
                case .add:
                    draft = DailyLogEntry()
                case .edit(let existing):
                    // 清單傳進來的 entry 不含照片（見 DailyLogRecord.summary），
                    // 直接拿它當 draft 存回去會把那天的照片全部洗掉。
                    // 所以這裡一定要用 fullEntry 把完整內容撈回來。
                    draft = store.fullEntry(id: existing.id) ?? existing
                }
            }
    }

    private func save() {
        store.upsert(draft)
    }
}
