import Foundation
import SQLite
import Testing
@testable import LawMaticDocumentIndex

@Test func storeWritesSchemaIdentityAndReopens() async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("LawMaticDocumentIndex-smoke-\(UUID().uuidString).sqlite")
    defer { removeSQLiteFiles(at: url) }

    let store = DocumentIndexStore(databaseURL: url)
    try await store.open()
    await store.close()

    let connection = try SQLite.Connection(url.path)
    let applicationID = try pragmaInt32(connection, "application_id")
    let userVersion = try pragmaInt32(connection, "user_version")
    let autoVacuum = try pragmaInt32(connection, "auto_vacuum")
    #expect(applicationID == DocumentIndexSchema.applicationID)
    #expect(userVersion == DocumentIndexSchema.userVersion)
    #expect(autoVacuum == 2, "auto_vacuum = INCREMENTAL должен быть выставлен при создании файла")

    try await store.open()
    await store.close()
}

@Test func storeRejectsIncompatibleDatabase() async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("LawMaticDocumentIndex-incompatible-\(UUID().uuidString).sqlite")
    defer { removeSQLiteFiles(at: url) }

    let seed = try SQLite.Connection(url.path)
    try seed.execute("PRAGMA application_id = 1;")
    try seed.execute("PRAGMA user_version = 1;")

    let store = DocumentIndexStore(databaseURL: url)
    await #expect(throws: DocumentIndexError.self) {
        try await store.open()
    }
}

@Test("Чужой непустой файл с нулевой идентичностью не штампуется как v2")
func storeRejectsForeignDatabaseWithZeroIdentity() async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("LawMaticDocumentIndex-foreign-\(UUID().uuidString).sqlite")
    defer { removeSQLiteFiles(at: url) }

    let seed = try SQLite.Connection(url.path)
    try seed.execute("CREATE TABLE case_records (id TEXT PRIMARY KEY);")

    let store = DocumentIndexStore(databaseURL: url)
    await #expect(throws: DocumentIndexError.self) {
        try await store.open()
    }
    #expect(try pragmaInt32(seed, "application_id") == 0, "идентичность чужого файла не изменена")
}

private func pragmaInt32(_ db: SQLite.Connection, _ name: String) throws -> Int32 {
    let value = try db.scalar("PRAGMA \(name)")
    if let int64 = value as? Int64 {
        return Int32(int64)
    }
    if let int = value as? Int {
        return Int32(int)
    }
    return 0
}

private func removeSQLiteFiles(at url: URL) {
    let fileManager = FileManager.default
    try? fileManager.removeItem(at: url)
    try? fileManager.removeItem(atPath: url.path + "-wal")
    try? fileManager.removeItem(atPath: url.path + "-shm")
}
