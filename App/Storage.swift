import Foundation
import Security
import SwiftData
import DowasureCore

/// One stored day. The record itself is kept as JSON so the schema can change freely.
@Model
final class StoredDay {
    @Attribute(.unique) var dateKey: String
    var payload: Data
    var updatedAt: Date

    init(record: DayRecord) {
        dateKey = record.date
        payload = (try? JSONEncoder().encode(record)) ?? Data()
        updatedAt = Date()
    }

    var record: DayRecord? { try? JSONDecoder().decode(DayRecord.self, from: payload) }

    func update(_ record: DayRecord) {
        payload = (try? JSONEncoder().encode(record)) ?? payload
        updatedAt = Date()
    }
}

@MainActor
enum RecordStore {
    static func allRecords(_ context: ModelContext) -> [DayRecord] {
        let days = (try? context.fetch(FetchDescriptor<StoredDay>(sortBy: [SortDescriptor(\.dateKey, order: .reverse)]))) ?? []
        return days.compactMap(\.record)
    }

    static func day(_ key: String, in context: ModelContext) -> StoredDay? {
        var descriptor = FetchDescriptor<StoredDay>(predicate: #Predicate { $0.dateKey == key })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    static func save(_ record: DayRecord, in context: ModelContext) throws {
        if let existing = day(record.date, in: context) {
            existing.update(record)
        } else {
            context.insert(StoredDay(record: record))
        }
        try context.save()
    }

    static func deleteAll(in context: ModelContext) throws {
        try context.delete(model: StoredDay.self)
        try context.save()
    }
}

/// Stores the API key in the iPhone keychain (never in the app or the repository).
enum APIKeyStore {
    private static let service = "io.github.tadfuji.dowasure.anthropic"
    private static let account = "api-key"

    /// Account name for the Google Cloud Text-to-Speech key (natural voice).
    static let voiceAccount = "google-tts-key"

    static func load(account: String = account) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    @discardableResult
    static func save(_ key: String, account: String = account) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        var add = base
        add[kSecValueData as String] = Data(trimmed.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
