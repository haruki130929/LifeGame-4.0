import SwiftData
import Foundation

@MainActor
final class MigrationManager {

    func migrateAllData(
        from source: ModelContainer,
        to destination: ModelContainer,
        modelTypes: [any PersistentModel.Type]
    ) throws {
        let sourceContext = ModelContext(source)
        let destinationContext = ModelContext(destination)
        destinationContext.autosaveEnabled = false

        for modelType in modelTypes {
            try migrateModelType(
                modelType,
                from: sourceContext,
                to: destinationContext
            )
        }

        do {
            try destinationContext.save()
        } catch {
            throw StorageError.migrationFailed(underlying: error)
        }
    }

    // MARK: - 依 Model 類型分發

    private func migrateModelType(
        _ modelType: any PersistentModel.Type,
        from source: ModelContext,
        to destination: ModelContext
    ) throws {
        // SwiftData 物件綁定 context，不能直接 insert 到另一個 context
        // 必須讀取屬性後建立新實例
        do {
            if modelType is KeyValueRecord.Type {
                try migrateKeyValueRecords(from: source, to: destination)
            } else if modelType is DailyLogRecord.Type {
                try migrateDailyLogRecords(from: source, to: destination)
            } else if modelType is BagItemModel.Type {
                try migrateBagItems(from: source, to: destination)
            } else {
                debugLog("⚠️ MigrationManager: 未知的 model type \(modelType)，跳過遷移")
            }
        } catch {
            throw StorageError.migrationFailed(underlying: error)
        }
    }

    // MARK: - KeyValueRecord 遷移

    private func migrateKeyValueRecords(
        from source: ModelContext,
        to destination: ModelContext
    ) throws {
        let sourceItems = try source.fetch(FetchDescriptor<KeyValueRecord>())
        guard !sourceItems.isEmpty else { return }

        // 取得目標已有的 keys，避免重複插入
        let existingItems = try destination.fetch(FetchDescriptor<KeyValueRecord>())
        let existingKeys = Set(existingItems.map(\.key))

        for item in sourceItems {
            if existingKeys.contains(item.key) {
                // 已存在 → 更新資料
                if let existing = existingItems.first(where: { $0.key == item.key }) {
                    existing.data = item.data
                    existing.updatedAt = item.updatedAt
                }
            } else {
                // 不存在 → 建立新副本
                let copy = KeyValueRecord(key: item.key, data: item.data)
                copy.updatedAt = item.updatedAt
                destination.insert(copy)
            }
        }
    }

    // MARK: - BagItemModel 遷移

    private func migrateBagItems(
        from source: ModelContext,
        to destination: ModelContext
    ) throws {
        let sourceItems = try source.fetch(FetchDescriptor<BagItemModel>())
        guard !sourceItems.isEmpty else { return }

        let existingItems = try destination.fetch(FetchDescriptor<BagItemModel>())
        let existingIDs = Set(existingItems.map(\.id))

        for item in sourceItems {
            if existingIDs.contains(item.id) {
                if let existing = existingItems.first(where: { $0.id == item.id }) {
                    existing.name = item.name
                    existing.icon = item.icon
                    existing.isRequired = item.isRequired
                    existing.isChecked = item.isChecked
                }
            } else {
                let copy = BagItemModel(
                    id: item.id,
                    name: item.name,
                    icon: item.icon,
                    isRequired: item.isRequired,
                    isChecked: item.isChecked
                )
                destination.insert(copy)
            }
        }
    }

    // MARK: - DailyLogRecord 遷移

    private func migrateDailyLogRecords(
        from source: ModelContext,
        to destination: ModelContext
    ) throws {
        let sourceItems = try source.fetch(FetchDescriptor<DailyLogRecord>())
        guard !sourceItems.isEmpty else { return }

        // 取得目標已有的 IDs，避免重複插入
        let existingItems = try destination.fetch(FetchDescriptor<DailyLogRecord>())
        let existingIDs = Set(existingItems.map(\.id))

        for item in sourceItems {
            if existingIDs.contains(item.id) {
                // 已存在 → 更新
                if let existing = existingItems.first(where: { $0.id == item.id }) {
                    existing.date = item.date
                    existing.payload = item.payload
                    existing.summary = item.summary
                }
            } else {
                // 不存在 → 建立新副本。summary 一起帶過去，省得搬完還要重新解一次 payload。
                let copy = DailyLogRecord(id: item.id, date: item.date,
                                          payload: item.payload, summary: item.summary)
                destination.insert(copy)
            }
        }
    }
}
