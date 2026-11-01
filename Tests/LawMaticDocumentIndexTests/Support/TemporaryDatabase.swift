import Foundation
import SQLite
@testable import LawMaticDocumentIndex

/// Временный файл базы v2 для тестов store; удаляется вместе с WAL/SHM.
final class TemporaryDatabase {
    let directoryURL: URL
    let databaseURL: URL

    init(name: String = "test") {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LawMaticDocumentIndexTests-\(UUID().uuidString)", isDirectory: true)
        databaseURL = directoryURL.appendingPathComponent("\(name).sqlite")
    }

    deinit {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    func openWriter(writerAppId: String = "lawmatic-finder") async throws -> DocumentIndexStore {
        let store = DocumentIndexStore(databaseURL: databaseURL, mode: .readWrite, writerAppId: writerAppId)
        try await store.open()
        return store
    }

    func openReader() async throws -> DocumentIndexStore {
        let store = DocumentIndexStore(databaseURL: databaseURL, mode: .readOnly)
        try await store.open()
        return store
    }

    /// Прямое соединение для проверок «снаружи» store.
    func rawConnection(readonly: Bool = true) throws -> SQLite.Connection {
        try SQLite.Connection(databaseURL.path, readonly: readonly)
    }

    func tableCount(_ table: String) throws -> Int {
        let value = try rawConnection().scalar("SELECT COUNT(*) FROM \(table)")
        if let int64 = value as? Int64 { return Int(int64) }
        if let int = value as? Int { return int }
        return 0
    }
}

func pragmaValue(_ db: SQLite.Connection, _ name: String) throws -> Int64 {
    let value = try db.scalar("PRAGMA \(name)")
    if let int64 = value as? Int64 { return int64 }
    if let int = value as? Int { return Int64(int) }
    return 0
}

func pragmaText(_ db: SQLite.Connection, _ name: String) throws -> String? {
    try db.scalar("PRAGMA \(name)") as? String
}

func queryPlan(_ db: SQLite.Connection, _ sql: String, _ bindings: [Binding] = []) throws -> [String] {
    var lines: [String] = []
    for row in try db.prepare("EXPLAIN QUERY PLAN " + sql, bindings) {
        if let detail = row[3] as? String { lines.append(detail) }
    }
    return lines
}
