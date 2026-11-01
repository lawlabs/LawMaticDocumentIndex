import Foundation
import SQLite
import Testing
@testable import LawMaticDocumentIndex

@Test("Новый файл получает все таблицы ядра, FTS-опции и метаданные версий")
func schemaIsCreatedOnEmptyFile() async throws {
    let temp = TemporaryDatabase()
    let store = try await temp.openWriter()
    await store.close()

    let db = try temp.rawConnection()
    var tables: Set<String> = []
    var fts: [String: String] = [:]
    for row in try db.prepare("SELECT name, sql FROM sqlite_master WHERE type = 'table'") {
        guard let name = row[0] as? String else { continue }
        tables.insert(name)
        if let sql = row[1] as? String, sql.contains("USING fts5") { fts[name] = sql }
    }
    for table in DocumentIndexSchema.coreTables {
        #expect(tables.contains(table), "таблица \(table) должна существовать")
    }
    for table in DocumentIndexSchema.extensionTables {
        #expect(tables.contains(table), "расширение \(table) должно существовать")
    }

    for name in ["chunk_fts", "documents_fts"] {
        let sql = fts[name] ?? ""
        #expect(sql.contains("content=''"), "\(name) должна быть contentless")
        #expect(sql.contains("contentless_delete=1"), "\(name) должна поддерживать адресное удаление")
        #expect(sql.contains(DocumentIndexSchema.ftsTokenizer), "\(name): токенизатор общий для всех индексов")
    }
    let chunkFTS = fts["chunk_fts"] ?? ""
    #expect(chunkFTS.contains("file_name_norm"), "chunk_fts индексирует имя файла")
    #expect(
        chunkFTS.range(of: "file_name_norm")!.lowerBound < chunkFTS.range(of: "content_norm")!.lowerBound,
        "порядок столбцов chunk_fts фиксирует веса bm25(имя, текст)"
    )

    #expect(try pragmaValue(db, "application_id") == Int64(DocumentIndexSchema.applicationID))
    #expect(try pragmaValue(db, "user_version") == Int64(DocumentIndexSchema.userVersion))
    #expect(try pragmaValue(db, "auto_vacuum") == 2, "auto_vacuum = INCREMENTAL выставлен до первой таблицы")
    #expect(try pragmaText(db, "journal_mode") == "wal")

    let metadata = try db.prepare("SELECT key, value FROM index_metadata").reduce(into: [String: String]()) {
        if let key = $1[0] as? String, let value = $1[1] as? String { $0[key] = value }
    }
    #expect(metadata[DocumentIndexSchema.MetadataKey.ftsNormalizerVersion] == String(DocumentIndexSchema.ftsNormalizerVersion))
    #expect(metadata[DocumentIndexSchema.MetadataKey.chunkingVersion] == String(DocumentIndexSchema.chunkingVersion))
    #expect(metadata[DocumentIndexSchema.MetadataKey.writerAppId] == "lawmatic-finder")
    #expect(metadata[DocumentIndexSchema.MetadataKey.schemaCreatedAt] != nil)
    #expect(metadata[DocumentIndexSchema.MetadataKey.finderExtensionVersion] == String(DocumentIndexSchema.finderExtensionVersion))
    #expect(metadata[DocumentIndexSchema.MetadataKey.indexGeneration]?.isEmpty == false)
    #expect(metadata["v1_import_disabled"] == nil)
}

@Test("Повторное открытие писателем не ломает существующую базу и не дублирует метаданные")
func schemaCreationIsIdempotent() async throws {
    let temp = TemporaryDatabase()
    let first = try await temp.openWriter()
    try await first.setMetadata("custom", "1")
    let generation = try await first.metadata(DocumentIndexSchema.MetadataKey.indexGeneration)
    await first.close()

    let second = try await temp.openWriter()
    #expect(try await second.metadata("custom") == "1")
    #expect(try await second.metadata(DocumentIndexSchema.MetadataKey.indexGeneration) == generation)
    #expect(try await second.integrityCheck().isEmpty)
    await second.close()

    let db = try temp.rawConnection()
    let created = try db.scalar("SELECT COUNT(*) FROM index_metadata WHERE key = ?", DocumentIndexSchema.MetadataKey.schemaCreatedAt) as? Int64
    #expect(created == 1)
}

@Test("Читатель открывает базу только для чтения и не может писать")
func readOnlyStoreRejectsWrites() async throws {
    let temp = TemporaryDatabase()
    let writer = try await temp.openWriter()
    try await writer.setMetadata("greeting", "привет")

    let reader = try await temp.openReader()
    #expect(try await reader.metadata("greeting") == "привет")
    await #expect(throws: DocumentIndexError.readOnly) {
        try await reader.setMetadata("greeting", "нельзя")
    }
    #expect(try await writer.metadata("greeting") == "привет")

    await reader.close()
    await writer.close()
}

@Test("Читатель отказывается открывать отсутствующий файл, не создавая его")
func readOnlyStoreDoesNotCreateFile() async throws {
    let temp = TemporaryDatabase()
    let reader = DocumentIndexStore(databaseURL: temp.databaseURL, mode: .readOnly)
    await #expect(throws: DocumentIndexError.databaseMissing(path: temp.databaseURL.path)) {
        try await reader.open()
    }
    #expect(!FileManager.default.fileExists(atPath: temp.databaseURL.path))
}

@Test("Писатель и читатель работают одновременно без SQLITE_BUSY; читатель видит data_version")
func concurrentWriterAndReader() async throws {
    let temp = TemporaryDatabase()
    let writer = try await temp.openWriter()
    let reader = try await temp.openReader()

    let initialVersion = try await reader.dataVersion()

    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            for index in 0..<200 {
                try await writer.setMetadata("counter", String(index))
            }
        }
        group.addTask {
            for _ in 0..<200 {
                _ = try await reader.metadata("counter")
                _ = try await reader.dataVersion()
            }
        }
        try await group.waitForAll()
    }

    #expect(try await reader.metadata("counter") == "199")
    #expect(try await reader.dataVersion() != initialVersion, "data_version меняется после чужой записи")

    await reader.close()
    await writer.close()
}

private extension DocumentIndexStore {
    /// Композиция публичных операций внутри одной транзакции: внутренний `write`
    /// становится SAVEPOINT и откатывается независимо от внешней транзакции.
    func nestedWriteProbe() throws -> Int {
        try write { _ in
            try setMetadata("outer", "1")
            do {
                try write { db in
                    try db.run("INSERT INTO index_metadata(key, value, updated_at_iso) VALUES ('inner', '1', 'x')")
                    throw DocumentIndexError.invalidArgument("откат вложенного")
                }
            } catch DocumentIndexError.invalidArgument {}
            return try collectOrphanTexts()
        }
    }
}

@Test("Вложенный write работает как SAVEPOINT: внутренний откат не трогает внешнюю транзакцию")
func nestedWriteUsesSavepoint() async throws {
    let temp = TemporaryDatabase()
    let store = try await temp.openWriter()
    let removed = try await store.nestedWriteProbe()
    #expect(removed == 0)
    #expect(try await store.metadata("outer") == "1")
    #expect(try await store.metadata("inner") == nil)
    try await store.setMetadata("after", "2")
    #expect(try await store.metadata("after") == "2")
    await store.close()
}

@Test("Сборка осиротевших текстов удаляет чанки, FTS-строки и эмбеддинги каскадом")
func orphanTextsAreCollected() async throws {
    let temp = TemporaryDatabase()
    let store = try await temp.openWriter()
    await store.close()

    let db = try temp.rawConnection(readonly: false)
    try db.execute("PRAGMA foreign_keys = ON")
    let now = "2026-09-02T00:00:00Z"
    try db.run("INSERT INTO texts(text_hash, content, utf16_length, created_at_iso) VALUES ('h1', 'договор поставки', 16, ?)", now)
    try db.run("INSERT INTO chunks(id, text_hash, chunk_index, utf16_start, utf16_end) VALUES ('h1:0', 'h1', 0, 0, 16)")
    let chunkRowid = db.lastInsertRowid
    try db.run("INSERT INTO chunk_fts(rowid, file_name_norm, content_norm) VALUES (?, '', 'договор поставк')", chunkRowid)
    try db.run("INSERT INTO embedding_models(model_id, provider, dim, quantization, created_at_iso) VALUES ('m', 'test', 4, 'int8', ?)", now)
    try db.run("INSERT INTO chunk_embeddings(chunk_rowid, model_id, scale, vector, created_at_iso) VALUES (?, 'm', 1.0, x'01020304', ?)", chunkRowid, now)

    let reopened = try await temp.openWriter()
    let removed = try await reopened.collectOrphanTexts()
    #expect(removed == 1)
    await reopened.close()

    #expect(try db.scalar("SELECT COUNT(*) FROM texts") as? Int64 == 0)
    #expect(try db.scalar("SELECT COUNT(*) FROM chunks") as? Int64 == 0)
    #expect(try db.scalar("SELECT COUNT(*) FROM chunk_embeddings") as? Int64 == 0)
    #expect(try db.scalar("SELECT COUNT(*) FROM chunk_fts WHERE chunk_fts MATCH 'договор'") as? Int64 == 0)
}

@Test("SQL областей: рекурсивная папка раскрывается CTE по parent_id, без LIKE и без SCAN documents")
func scopeSQLUsesIndexesOnly() async throws {
    let temp = TemporaryDatabase()
    let store = try await temp.openWriter()
    await store.close()

    let db = try temp.rawConnection(readonly: false)
    try db.execute("PRAGMA foreign_keys = ON")
    let now = "2026-09-02T00:00:00Z"
    try db.run("INSERT INTO workspace_roots VALUES ('root-1', 'РАБОТА', '/Users/x/РАБОТА', 'lawmatic-finder', ?, ?)", now, now)
    try db.run("INSERT INTO folders(id, workspace_root_id, parent_id, relative_path, depth) VALUES (1, 'root-1', NULL, '', 0)")
    try db.run("INSERT INTO folders(id, workspace_root_id, parent_id, relative_path, depth) VALUES (2, 'root-1', 1, 'Дело', 1)")
    try db.run("INSERT INTO folders(id, workspace_root_id, parent_id, relative_path, depth) VALUES (3, 'root-1', 2, 'Дело/Иски', 2)")
    try db.run("INSERT INTO folders(id, workspace_root_id, parent_id, relative_path, depth) VALUES (4, 'root-1', 1, 'Другое', 1)")
    for (id, folder, path) in [("d1", 2, "Дело/а.docx"), ("d2", 3, "Дело/Иски/б.docx"), ("d3", 4, "Другое/в.docx")] {
        try db.run(
            """
            INSERT INTO documents(id, location_kind, workspace_root_id, folder_id, relative_path, file_name, file_name_lower,
                file_extension, file_size, file_modified_iso, created_by_app, created_at_iso, updated_at_iso)
            VALUES (?, 'workspace', 'root-1', ?, ?, 'x', 'x', 'docx', 1, ?, 'lawmatic-finder', ?, ?)
            """,
            id, Int64(folder), path, now, now, now
        )
    }

    let scopes: [(SearchScope, Set<String>)] = [
        (.folderPath(workspaceRootId: "root-1", relativePath: "Дело", recursive: true), ["d1", "d2"]),
        (.folderPath(workspaceRootId: "root-1", relativePath: "Дело", recursive: false), ["d1"]),
        (.folder(id: 1, recursive: true), ["d1", "d2", "d3"]),
        (.workspaceRoot(id: "root-1"), ["d1", "d2", "d3"]),
        (.documents(ids: ["d2", "d3"]), ["d2", "d3"]),
        (.externalOnly, []),
        (.everything, ["d1", "d2", "d3"]),
    ]

    for (scope, expected) in scopes {
        let fragment = ScopeSQL(scope: scope)
        let sql = fragment.withClause + "SELECT d.id FROM documents d WHERE \(fragment.predicate)"
        #expect(!sql.contains("LIKE"), "область не использует LIKE: \(scope)")

        var ids: Set<String> = []
        for row in try db.prepare(sql, fragment.bindings) {
            if let id = row[0] as? String { ids.insert(id) }
        }
        #expect(ids == expected, "область \(scope)")

        if case .everything = scope { continue }
        // В плане таблица фигурирует под алиасом: «SCAN d», а не «SCAN documents».
        let plan = try queryPlan(db, sql, fragment.bindings)
        let fullScan = plan.contains { $0 == "SCAN d" || $0.hasPrefix("SCAN d ") || $0.hasPrefix("SCAN documents") }
        #expect(!fullScan, "план без полного просмотра documents: \(plan)")
    }
}
