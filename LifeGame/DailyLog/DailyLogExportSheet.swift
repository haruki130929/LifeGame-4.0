import SwiftUI

struct DailyLogExportSheet: View {
    /// 不含照片的輕量紀錄，只用來挑日期區間（見 DailyLogRecord.summary）
    let allEntries: [DailyLogEntry]
    /// 把選中的那幾筆換成含照片的完整版。沒有它，匯出的照片數會變成 0。
    let loadFull: (UUID) -> DailyLogEntry?

    @EnvironmentObject private var moduleStore: QuestionModuleStore
    @Environment(\.dismiss) private var dismiss

    enum ExportFormat: String, CaseIterable, Identifiable {
        case pdf = "PDF"
        case text = "文字檔"
        var id: String { rawValue }
        var fileExtension: String { self == .pdf ? "pdf" : "txt" }
    }

    @State private var startDate: Date = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .now
    @State private var endDate: Date = .now
    @State private var format: ExportFormat = .pdf

    // 已確認的區間（按「確定」後才設定，筆數與匯出都以此為準）
    @State private var appliedStart: Date? = nil
    @State private var appliedEnd: Date? = nil

    @State private var isGenerating = false
    @State private var shareURL: URL? = nil
    @State private var errorMessage: String? = nil

    private var isConfirmed: Bool { appliedStart != nil && appliedEnd != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("選擇時間期限") {
                    DatePicker("開始日期", selection: $startDate, displayedComponents: .date)
                        .onChange(of: startDate) { _, _ in resetConfirmation() }
                    DatePicker("結束日期", selection: $endDate, displayedComponents: .date)
                        .onChange(of: endDate) { _, _ in resetConfirmation() }

                    if !isConfirmed {
                        Button {
                            confirmRange()
                        } label: {
                            Label("確定", systemImage: "checkmark.circle")
                        }
                    }
                }

                if isConfirmed {
                    Section {
                        HStack {
                            Text("此期間紀錄")
                            Spacer()
                            Text("\(confirmedEntries.count) 筆")
                                .foregroundStyle(.secondary)
                        }
                        Button("重選區間") { resetConfirmation() }
                            .foregroundStyle(.secondary)
                    }

                    Section("匯出格式") {
                        Picker("格式", selection: $format) {
                            ForEach(ExportFormat.allCases) { f in
                                Text(f.displayName).tag(f)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: format) { _, _ in shareURL = nil }

                        Text(format == .pdf
                             ? "排版完整、含照片，適合列印或分享給他人。"
                             : "純文字，檔案小、方便複製貼上（不含照片）。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Section {
                        Button {
                            generate()
                        } label: {
                            HStack {
                                if isGenerating {
                                    ProgressView()
                                    Text("產生中…")
                                } else {
                                    Label("產生檔案", systemImage: "doc.badge.plus")
                                }
                            }
                        }
                        .disabled(confirmedEntries.isEmpty || isGenerating)

                        if let shareURL {
                            ShareLink(item: shareURL) {
                                Label("分享 / 儲存檔案", systemImage: "square.and.arrow.up")
                            }
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("匯出每日紀錄")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("關閉") { dismiss() }
                }
            }
        }
    }

    // MARK: - 確認區間

    private func confirmRange() {
        let (s, e) = normalizedRange
        appliedStart = s
        appliedEnd = e
        errorMessage = nil
    }

    private func resetConfirmation() {
        appliedStart = nil
        appliedEnd = nil
        errorMessage = nil
        shareURL = nil
    }

    // MARK: - 產生

    private func generate() {
        guard let s = appliedStart, let e = appliedEnd else { return }
        errorMessage = nil
        isGenerating = true

        let entries = confirmedEntries
        let title = rangeTitle(s, e)
        let stamp = fileStamp(s, e)

        // ImageRenderer / 大量序列化需在主執行緒，下一個 runloop 執行讓 ProgressView 先顯示
        DispatchQueue.main.async {
            defer { isGenerating = false }
            do {
                let url: URL
                switch format {
                case .text:
                    let text = DailyLogTextExporter(moduleStore: moduleStore)
                        .makeText(for: entries, rangeTitle: title)
                    url = try write(data: Data(text.utf8), ext: "txt", stamp: stamp)
                case .pdf:
                    guard let data = DailyLogPDFRenderer.makePDF(for: entries,
                                                                 rangeTitle: title,
                                                                 moduleStore: moduleStore) else {
                        errorMessage = String(localized: "PDF 產生失敗，請稍後再試。")
                        return
                    }
                    url = try write(data: data, ext: "pdf", stamp: stamp)
                }
                shareURL = url
            } catch {
                errorMessage = String(localized: "檔案寫入失敗：\(error.localizedDescription)")
            }
        }
    }

    private func write(data: Data, ext: String, stamp: String) throws -> URL {
        let fileName = String(localized: "每日紀錄_\(stamp).\(ext)")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: url)
        try data.write(to: url)
        return url
    }

    // MARK: - 日期 / 篩選

    private var normalizedRange: (start: Date, end: Date) {
        let cal = Calendar.current
        let s = cal.startOfDay(for: min(startDate, endDate))
        let e = cal.startOfDay(for: max(startDate, endDate))
        return (s, e)
    }

    /// 已確認區間內的紀錄（筆數與匯出都用這份，確保一致）
    private var confirmedEntries: [DailyLogEntry] {
        guard let s = appliedStart, let e = appliedEnd else { return [] }
        let cal = Calendar.current
        return allEntries
            .filter { entry in
                let d = cal.startOfDay(for: entry.date)
                return d >= s && d <= e
            }
            .sorted { $0.date < $1.date }
            // 只有真的要匯出的那幾天才去撈照片
            .map { loadFull($0.id) ?? $0 }
    }

    private func rangeTitle(_ s: Date, _ e: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = .current
        fmt.setLocalizedDateFormatFromTemplate("yMMMd")
        return "\(fmt.string(from: s)) – \(fmt.string(from: e))"
    }

    private func fileStamp(_ s: Date, _ e: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd"
        return "\(fmt.string(from: s))-\(fmt.string(from: e))"
    }
}
