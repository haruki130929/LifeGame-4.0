import Foundation
import Combine
import SwiftUI
import SwiftData

@MainActor
final class DailyLogStore: ObservableObject {
    
    @Published private(set) var entries: [DailyLogEntry] = []
    @Published private(set) var initError: String?

    private let context: ModelContext?
    private var isLoading = false
    private var syncHelper: StoreSyncHelper?

    /// `entries` 是否已經實際載入過。
    ///
    /// 這個 store 由 `HomeRootContainerView` 在首頁出現時建立，而載入一次要把每一筆
    /// `DailyLogRecord.payload` 整個 JSON 解碼 —— payload 裡含 `photos`，照片在 JSON 裡
    /// 是 base64，實測資料庫 372 MB。以前 `init` 直接同步跑，等於每次開 App 都在主執行緒
    /// 上解一次全部照片，那就是啟動要等好幾秒的原因。
    ///
    /// 現在改成誰要用誰負責叫 `ensureLoaded()`。目前只有 `DailyLogHistoryView`（圖表、
    /// 清單、匯出）真的需要整份 `entries`，而那是使用者主動點進去的畫面。
    @Published private(set) var isLoaded = false

    /// 正在跑第一次載入。給畫面顯示「載入中」用。
    @Published private(set) var isPreparing = false

    /// 建立 in-memory fallback 容器（StorageCoordinator 不可用時）
    private static func makeInMemoryContext() -> ModelContext? {
        // in-memory 容器幾乎不可能失敗，但仍做防護
        do {
            let container = try ModelContainer(
                for: DailyLogRecord.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
            return ModelContext(container)
        } catch {
            debugLog("❌ DailyLogStore: in-memory 容器也失敗: \(error)")
            // 極端情況：用最簡化設定再試一次（仍做 do-catch 防護）
            do {
                let container = try ModelContainer(for: DailyLogRecord.self)
                return ModelContext(container)
            } catch {
                // 所有初始化都失敗：降級為「無儲存」模式，但不讓 App 崩潰（原本是 fatalError）
                debugLog("❌ DailyLogStore: 所有 ModelContainer 配置都失敗，每日紀錄將暫時無法使用: \(error)")
                return nil
            }
        }
    }

    init(context: ModelContext? = nil) {
        if let context {
            self.context = context
        } else if let coord = StorageManager.coordinator {
            // 使用共享的 mainContext：CloudKit 遠端 import 會自動 merge 進 mainContext，
            // 自建獨立 ModelContext 不會收到遠端變更（造成每日紀錄無法跨裝置同步）
            self.context = coord.mainContext
        } else {
            debugLog("⚠️ DailyLogStore: StorageCoordinator 尚未初始化，使用 in-memory 容器")
            let fallback = Self.makeInMemoryContext()
            self.context = fallback
            self.initError = fallback == nil
                ? String(localized: "儲存系統無法初始化，每日紀錄暫時無法使用")
                : String(localized: "儲存系統尚未就緒，資料暫存於記憶體中")
        }
        // 這裡刻意不載入。載入成本與資料量成正比（見 isLoaded 的說明），
        // 而首頁完全不需要 entries —— 需要的畫面會自己叫 ensureLoaded()。
        // 監聽 CloudKit 遠端變更，自動重新載入
        syncHelper = StoreSyncHelper { [weak self] in
            self?.reloadIfLoaded()
        }
    }

    /// 真正需要整份 `entries` 的畫面要先叫這個。重複呼叫無害。
    ///
    /// `load()` 是同步的、會擋住主執行緒，所以先 yield 一幀讓「載入中」先畫出來；
    /// 否則使用者會先看到一片「還沒有紀錄」的空畫面，然後畫面整個凍住。
    func ensureLoaded() {
        guard !isLoaded, !isPreparing else { return }
        isPreparing = true
        Task { @MainActor in
            await Task.yield()
            load()
            isLoaded = true
            isPreparing = false
        }
    }

    /// 只有在已經載入過的情況下才重新載入。
    /// 沒載入過就重載等於把省下來的成本又花掉，而且畫面上根本沒人在看 entries。
    private func reloadIfLoaded() {
        guard isLoaded else { return }
        load()
    }

    func addToday() -> DailyLogEntry {
        if let existing = entry(for: Date()) { return existing }
        var e = DailyLogEntry()
        e.date = Date()
        upsert(e)
        return e
    }

    /// 查某一天的**完整**紀錄（含照片）。
    ///
    /// 一律查資料庫，不掃 `entries`，有兩個原因：
    /// 1. 還沒 `ensureLoaded()` 時 `entries` 是空的，掃它會誤判成「今天還沒寫」，
    ///    `addToday()` 就會再開一筆新的，把當天蓋掉。
    /// 2. `entries` 裡的紀錄不含照片，回傳它等於交出一個存回去就會洗掉照片的物件。
    ///
    /// 只解碼命中的那一筆，成本與資料總量無關。
    func entry(for date: Date) -> DailyLogEntry? {
        guard let context else { return nil }
        let cal = Calendar.current
        let start = cal.startOfDay(for: date)
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return nil }
        do {
            var descriptor = FetchDescriptor<DailyLogRecord>(
                predicate: #Predicate { $0.date >= start && $0.date < end },
                sortBy: [SortDescriptor(\.date, order: .reverse)]
            )
            descriptor.fetchLimit = 1
            return try context.fetch(descriptor).first?.entry
        } catch {
            debugLog("DailyLogStore entry(for:) failed:", error)
            return nil
        }
    }
    
    func upsert(_ entry: DailyLogEntry) {
        guard let context else {
            ErrorManager.shared.showError(initError ?? String(localized: "儲存系統尚未就緒"))
            return
        }
        do {
            // 先編碼一次：失敗會丟出 → 進 catch 通知使用者，且不會把既有資料覆蓋成空白
            let payload = try JSONEncoder().encode(entry)

            let descriptor = FetchDescriptor<DailyLogRecord>(
                predicate: #Predicate { $0.id == entry.id }
            )

            // summary 必須跟 payload 一起寫，否則清單會顯示舊內容（它讀的是 summary）
            let summary = DailyLogRecord.encodeSummary(entry)

            if let existing = try context.fetch(descriptor).first {
                existing.id = entry.id
                existing.date = entry.date
                existing.payload = payload
                existing.summary = summary
            } else {
                context.insert(DailyLogRecord(id: entry.id, date: entry.date,
                                              payload: payload, summary: summary))
            }

            try context.save()
            reloadIfLoaded()
        } catch {
            debugLog("DailyLogStore upsert failed:", error)
            ErrorManager.shared.showError(L10n.Error.saveFailed, error: error)
        }
    }
    
    /// 刪除指定日期之後的紀錄
    func deleteAfter(_ cutoffDate: Date) {
        guard let context else { return }
        do {
            let cal = Calendar.current
            let cutoff = cal.startOfDay(for: cutoffDate)
            // 用 record.date 這個欄位判斷，不要用 record.entry.date ——
            // 後者會把每一筆 payload（含照片 base64）整個解碼一次，只為了讀一個日期。
            let descriptor = FetchDescriptor<DailyLogRecord>(
                predicate: #Predicate { $0.date >= cutoff }
            )
            let records = try context.fetch(descriptor)
            let count = records.count
            for record in records {
                context.delete(record)
            }
            try context.save()
            reloadIfLoaded()
            debugLog("✅ DailyLog 清除 \(cutoff) 之後的紀錄，共刪除 \(count) 筆")
        } catch {
            debugLog("DailyLogStore deleteAfter failed:", error)
        }
    }

    func delete(at offsets: IndexSet) {
        guard let context else { return }
        do {
            let items = offsets.compactMap { idx in
                entries.indices.contains(idx) ? entries[idx] : nil
            }
            
            for e in items {
                let descriptor = FetchDescriptor<DailyLogRecord>(
                    predicate: #Predicate { $0.id == e.id }
                )
                if let record = try context.fetch(descriptor).first {
                    context.delete(record)
                }
            }
            
            try context.save()
            reloadIfLoaded()
        } catch {
            debugLog("DailyLogStore delete failed:", error)
            ErrorManager.shared.showError(L10n.Error.deleteFailed, error: error)
        }
    }
    
    private func load() {
        guard !isLoading else { return }
        guard let context else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let descriptor = FetchDescriptor<DailyLogRecord>()
            let records = try context.fetch(descriptor)

            // 去重（在背景做，不影響 UI）
            let needsDedup = deduplicateRecords(records, context: context)

            let finalRecords: [DailyLogRecord]
            if needsDedup {
                try context.save()
                finalRecords = try context.fetch(descriptor)
            } else {
                finalRecords = records
            }

            // 讀 summary（不含照片）而不是 payload。清單與圖表都用不到照片，
            // 而解開照片的 base64 正是這個畫面以前要等好幾秒的原因。
            var arr: [DailyLogEntry] = finalRecords.map { $0.summaryEntry }
            arr.sort { $0.date > $1.date }
            self.entries = arr

            backfillSummariesIfNeeded(finalRecords)
        } catch {
            debugLog("DailyLogStore load failed:", error)
        }
    }

    /// 替還沒有 summary 的紀錄補寫（舊資料，或剛從別台裝置同步下來的）。
    ///
    /// 補寫本身要解 payload，所以排到下一輪 runloop、一次只做少量，不擋住剛畫好的畫面。
    /// 沒補完也沒關係 —— `summaryEntry` 會自動退回解 payload，下次進來再補下一批。
    ///
    /// 只把 id 帶進 `Task`：`DailyLogRecord` 與 `ModelContext` 都不是 `Sendable`，
    /// 直接捕捉會過不了 Swift 6 的檢查。UUID 是 Sendable，進去之後再重新撈。
    private func backfillSummariesIfNeeded(_ records: [DailyLogRecord]) {
        let pendingIDs = records.filter(\.needsSummaryBackfill).map(\.id)
        guard !pendingIDs.isEmpty else { return }

        let batch = Array(pendingIDs.prefix(20))
        let remaining = pendingIDs.count - batch.count

        Task { @MainActor [weak self] in
            guard let self, let context = self.context else { return }
            for id in batch {
                var descriptor = FetchDescriptor<DailyLogRecord>(
                    predicate: #Predicate { $0.id == id }
                )
                descriptor.fetchLimit = 1
                guard let record = try? context.fetch(descriptor).first else { continue }
                record.rebuildSummary()
            }
            do {
                try context.save()
                debugLog("✅ DailyLog 補寫 summary \(batch.count) 筆，剩 \(remaining) 筆")
            } catch {
                debugLog("DailyLog summary 補寫失敗：", error)
            }
        }
    }

    /// 取某一筆的完整紀錄（含照片）。編輯與匯出照片時才用。
    ///
    /// `entries` 裡的紀錄一律不含照片，直接拿去存會把照片洗掉 —— 所以編輯畫面
    /// 必須先用這個把完整內容撈回來。
    func fullEntry(id: UUID) -> DailyLogEntry? {
        guard let context else { return nil }
        do {
            var descriptor = FetchDescriptor<DailyLogRecord>(
                predicate: #Predicate { $0.id == id }
            )
            descriptor.fetchLimit = 1
            return try context.fetch(descriptor).first?.entry
        } catch {
            debugLog("DailyLogStore fullEntry failed:", error)
            return nil
        }
    }

    /// 去重，回傳是否有刪除任何 record
    @discardableResult
    private func deduplicateRecords(_ records: [DailyLogRecord], context: ModelContext) -> Bool {
        var deleted = false

        // 同一個 id 有多筆時，刪掉多餘的
        let groupedById = Dictionary(grouping: records, by: \.id)
        for (_, dups) in groupedById where dups.count > 1 {
            for dup in dups.dropFirst() {
                context.delete(dup)
                deleted = true
            }
        }

        // 同一天有不同 id 的紀錄時，保留最後一筆
        let cal = Calendar.current
        let remaining = records.filter { !$0.isDeleted }
        let groupedByDay = Dictionary(grouping: remaining) { r in
            cal.startOfDay(for: r.date)
        }
        for (_, dayRecords) in groupedByDay where dayRecords.count > 1 {
            for dup in dayRecords.dropLast() {
                context.delete(dup)
                deleted = true
                debugLog("🧹 DailyLog 去重：刪除同一天的重複紀錄 \(dup.date)")
            }
        }

        return deleted
    }
}
