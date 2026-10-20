import Foundation
import SwiftData

@Model
final class DailyLogRecord {
    var id: UUID = UUID()
    var date: Date = Date()

    /// 完整紀錄（含 `photos`）。照片在 JSON 裡是 base64，所以這一欄可能是好幾 MB。
    /// **只有在開啟某一天的紀錄時才該讀它。**
    var payload: Data = Data()

    /// 同一筆紀錄但把 `photos` 拿掉的版本，通常只有幾 KB。
    ///
    /// 清單與圖表不需要照片，卻要把每一筆都解碼一次 —— 以前它們讀 `payload`，
    /// 等於為了畫一張情緒折線圖去解開全部照片的 base64（實測資料庫 372 MB）。
    /// 有了這一欄，清單只要讀它就好，成本降到幾乎為零。
    ///
    /// 這是**衍生資料**：永遠可以從 `payload` 重算，所以就算它壞了或空著也不會掉資料，
    /// 讀取端會自動退回去解 `payload` 並順手補寫回來。
    var summary: Data = Data()

    init(id: UUID, date: Date, payload: Data, summary: Data = Data()) {
        self.id = id
        self.date = date
        self.payload = payload
        self.summary = summary
    }

    // 既有：entry -> record
    convenience init(entry: DailyLogEntry) {
        // 編碼失敗時退回空資料（已記錄錯誤，避免完全無聲無息）
        let data = Self.encodeEntry(entry) ?? Data()
        self.init(id: entry.id, date: entry.date,
                  payload: data, summary: Self.encodeSummary(entry))
    }

    // ✅ 相容層：外部如果寫 DailyLogRecord(from: entry)
    convenience init(from entry: DailyLogEntry) {
        self.init(entry: entry)
    }

    func decodeEntry() -> DailyLogEntry? {
        Self.decodeEntry(from: payload)
    }

    // ✅ 相容層：外部如果要 record.entry 直接拿到 DailyLogEntry
    // 若 decode 失敗，就回傳一個「至少不會崩」的預設值（id/date 會對齊 record）
    var entry: DailyLogEntry {
        if let e = decodeEntry() { return e }
        var e = DailyLogEntry()
        e.id = id
        e.date = date
        return e
    }

    func update(from entry: DailyLogEntry) {
        // 編碼成功才覆蓋；失敗則保留原本內容，避免把既有資料洗成空白
        guard let data = Self.encodeEntry(entry) else {
            debugLog("⚠️ DailyLogRecord.update 編碼失敗，保留原本內容不覆蓋（id=\(entry.id)）")
            return
        }
        id = entry.id
        date = entry.date
        payload = data
        summary = Self.encodeSummary(entry)
    }

    // ✅ 相容層：外部如果寫 record.update(entry: xxx)
    func update(entry: DailyLogEntry) {
        update(from: entry)
    }

    // MARK: - Nonisolated helpers（避免 Swift 6 concurrency 警告）

    private nonisolated static func encodeEntry(_ entry: DailyLogEntry) -> Data? {
        do {
            return try JSONEncoder().encode(entry)
        } catch {
            debugLog("❌ DailyLogRecord 編碼失敗：\(error)")
            return nil
        }
    }

    // MARK: - Summary（不含照片的輕量版）

    /// 把照片拿掉再編碼。編碼失敗回傳空 Data —— 讀取端看到空的會自動退回解 `payload`。
    nonisolated static func encodeSummary(_ entry: DailyLogEntry) -> Data {
        var light = entry
        light.photos = []
        return (try? JSONEncoder().encode(light)) ?? Data()
    }

    /// 清單／圖表用的輕量紀錄。`photos` 一定是空的。
    ///
    /// `summary` 還沒補上時（舊資料、或剛從別台裝置同步下來）退回解 `payload`，
    /// 保證畫面永遠正確，只是那一筆比較慢。補寫由 `DailyLogStore` 負責。
    /// 兩邊都解不開時回傳一個對齊 id/date 的預設值，跟 `entry` 的行為一致 ——
    /// 這樣壞掉的紀錄會在清單上顯示成空白列，而不是整筆從畫面上消失。
    var summaryEntry: DailyLogEntry {
        if !summary.isEmpty, let e = Self.decodeEntry(from: summary) { return e }
        if var full = Self.decodeEntry(from: payload) {
            full.photos = []
            return full
        }
        var fallback = DailyLogEntry()
        fallback.id = id
        fallback.date = date
        return fallback
    }

    /// `summary` 是否需要補寫。
    var needsSummaryBackfill: Bool { summary.isEmpty && !payload.isEmpty }

    /// 從目前的 `payload` 重算 `summary`。
    func rebuildSummary() {
        guard let full = Self.decodeEntry(from: payload) else { return }
        summary = Self.encodeSummary(full)
    }

    private nonisolated static func decodeEntry(from data: Data) -> DailyLogEntry? {
        do {
            return try JSONDecoder().decode(DailyLogEntry.self, from: data)
        } catch {
            debugLog("❌ DailyLogRecord 解碼失敗（payload \(data.count) bytes）：\(error)")
            return nil
        }
    }
}
