import Foundation
import SQLite

public struct DocumentIndexReaderCapabilities: Equatable, Sendable {
    public let finderExtensionVersion: Int?
    public let requiredFeatures: [String]
    public let supportsExplicitCaseDocuments: Bool
}

extension DocumentIndexStore {
    public func readerCapabilities() throws -> DocumentIndexReaderCapabilities {
        try currentCapabilities()
    }

    /// A live reader can observe metadata/schema changes on another connection.
    /// data_version costs one PRAGMA; the full contract is read only when it changes.
    func currentCapabilities() throws -> DocumentIndexReaderCapabilities {
        let connection = try db()
        let version = try Self.pragmaInt64(connection, "data_version")
        if let cachedReaderCapabilities, cachedReaderCapabilities.dataVersion == version {
            return cachedReaderCapabilities.value
        }
        let value = try Self.readCapabilities(connection)
        noteCapabilityRead()
        cachedReaderCapabilities = (version, value)
        return value
    }

    static func readCapabilities(_ db: SQLite.Connection) throws -> DocumentIndexReaderCapabilities {
        let version = (try db.scalar("SELECT value FROM index_metadata WHERE key = ?",
            DocumentIndexSchema.MetadataKey.finderExtensionVersion) as? String).flatMap(Int.init)
        let json = try db.scalar("SELECT value FROM index_metadata WHERE key = ?",
            DocumentIndexSchema.MetadataKey.readerRequiredFeatures) as? String
        let features: [String]
        if let json {
            guard let data = json.data(using: .utf8), let parsed = try? JSONDecoder().decode([String].self, from: data) else {
                throw DocumentIndexError.invalidArgument("Повреждено описание возможностей индекса. Создайте новый снимок в Finder.")
            }
            features = parsed
        } else { features = [] }
        let unknown = Set(features).subtracting(DocumentIndexSchema.supportedReaderFeatures)
        guard unknown.isEmpty else {
            throw DocumentIndexError.invalidArgument("Для этого снимка обновите LawMatic B2: неизвестные возможности \(unknown.sorted().joined(separator: ", ")).")
        }
        let exists = try db.scalar("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'case_document_links'") != nil
        if exists {
            let columns = Set(try db.prepare("PRAGMA table_info(case_document_links)").compactMap { $0[1] as? String })
            guard columns.isSuperset(of: ["case_id", "document_id", "attached_at_iso", "sort_index"]) else {
                throw DocumentIndexError.invalidArgument("Повреждена таблица вложений дела. Создайте новый снимок в Finder.")
            }
        }
        if features.contains("explicit_case_documents") || (version ?? 0) >= 4 {
            guard exists else { throw DocumentIndexError.invalidArgument("Индекс требует обновления в Finder: таблица вложений дела отсутствует.") }
        }
        return DocumentIndexReaderCapabilities(finderExtensionVersion: version, requiredFeatures: features,
                                               supportsExplicitCaseDocuments: exists)
    }
}
