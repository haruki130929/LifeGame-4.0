import Foundation
import SwiftData

// MARK: - Backup Payload

struct BackupPayload: Codable {
    let version: Int
    let exportedAt: Date
    let keyValueRecords: [KVBackupEntry]
    let dailyLogRecords: [DailyLogBackupEntry]
    let bagItems: [BagItemBackupEntry]

    static let currentVersion = 1
}

struct KVBackupEntry: Codable {
    let key: String
    let data: Data      // 原始 JSON Data
    let updatedAt: Date
}

struct DailyLogBackupEntry: Codable {
    let id: UUID
    let date: Date
    let payload: Data   // DailyLogEntry 的 JSON Data
}

struct BagItemBackupEntry: Codable {
    let id: UUID
    let name: String
    let icon: String
    let isRequired: Bool
    let isChecked: Bool
}

// MARK: - BackupManager

@MainActor
enum BackupManager {

    // MARK: - Export

    static func exportBackup(context: ModelContext) throws -> Data {
        // 1. KeyValueRecord
        let kvDescriptor = FetchDescriptor<KeyValueRecord>()
        let kvRecords = try context.fetch(kvDescriptor)
        let kvEntries = kvRecords.map { record in
            KVBackupEntry(key: record.key, data: record.data, updatedAt: record.updatedAt)
        }

        // 2. DailyLogRecord
        let dailyDescriptor = FetchDescriptor<DailyLogRecord>()
        let dailyRecords = try context.fetch(dailyDescriptor)
        let dailyEntries = dailyRecords.map { record in
            DailyLogBackupEntry(id: record.id, date: record.date, payload: record.payload)
        }

        // 3. BagItemModel
        let bagDescriptor = FetchDescriptor<BagItemModel>()
        let bagItems = try context.fetch(bagDescriptor)
        let bagEntries = bagItems.map { item in
            BagItemBackupEntry(
                id: item.id,
                name: item.name,
                icon: item.icon,
                isRequired: item.isRequired,
                isChecked: item.isChecked
            )
        }

        // 4. 組裝
        let payload = BackupPayload(
            version: BackupPayload.currentVersion,
            exportedAt: Date(),
            keyValueRecords: kvEntries,
            dailyLogRecords: dailyEntries,
            bagItems: bagEntries
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(payload)
    }

    // MARK: - Import

    static func importBackup(from data: Data, context: ModelContext) throws -> ImportResult {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(BackupPayload.self, from: data)

        var result = ImportResult()

        // 1. KeyValueRecord — upsert by key
        for entry in payload.keyValueRecords {
            var descriptor = FetchDescriptor<KeyValueRecord>(
                predicate: #Predicate { $0.key == entry.key }
            )
            descriptor.fetchLimit = 1

            if let existing = try context.fetch(descriptor).first {
                existing.data = entry.data
                existing.updatedAt = entry.updatedAt
                result.kvUpdated += 1
            } else {
                let record = KeyValueRecord(key: entry.key, data: entry.data)
                record.updatedAt = entry.updatedAt
                context.insert(record)
                result.kvInserted += 1
            }
        }

        // 2. DailyLogRecord — upsert by id
        for entry in payload.dailyLogRecords {
            var descriptor = FetchDescriptor<DailyLogRecord>(
                predicate: #Predicate { $0.id == entry.id }
            )
            descriptor.fetchLimit = 1

            // 備份檔裡沒有 summary（它是衍生資料，不值得佔備份空間），所以匯入後要重算。
            // 不重算的話，舊的 summary 會留著，清單就會顯示匯入前的內容。
            if let existing = try context.fetch(descriptor).first {
                existing.date = entry.date
                existing.payload = entry.payload
                existing.rebuildSummary()
                result.dailyLogUpdated += 1
            } else {
                let record = DailyLogRecord(id: entry.id, date: entry.date, payload: entry.payload)
                record.rebuildSummary()
                context.insert(record)
                result.dailyLogInserted += 1
            }
        }

        // 3. BagItemModel — upsert by id
        for entry in payload.bagItems {
            var descriptor = FetchDescriptor<BagItemModel>(
                predicate: #Predicate { $0.id == entry.id }
            )
            descriptor.fetchLimit = 1

            if let existing = try context.fetch(descriptor).first {
                existing.name = entry.name
                existing.icon = entry.icon
                existing.isRequired = entry.isRequired
                existing.isChecked = entry.isChecked
                result.bagUpdated += 1
            } else {
                context.insert(BagItemModel(
                    id: entry.id,
                    name: entry.name,
                    icon: entry.icon,
                    isRequired: entry.isRequired,
                    isChecked: entry.isChecked
                ))
                result.bagInserted += 1
            }
        }

        try context.save()
        return result
    }

    // MARK: - Backup file name

    static func backupFileName() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HHmmss"
        return "LifeGame_Backup_\(fmt.string(from: Date())).json"
    }
}

// MARK: - Import Result

struct ImportResult {
    var kvInserted = 0
    var kvUpdated = 0
    var dailyLogInserted = 0
    var dailyLogUpdated = 0
    var bagInserted = 0
    var bagUpdated = 0

    var summary: String {
        let total = kvInserted + kvUpdated + dailyLogInserted + dailyLogUpdated + bagInserted + bagUpdated
        return String(localized: "已匯入 \(total) 筆資料")
    }
}
