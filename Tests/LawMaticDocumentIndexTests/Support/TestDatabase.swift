import Foundation
import SQLite3
@testable import LawMaticDocumentIndex

/// In-memory SQLite через C API: проверяем поведение FTS5 самой библиотеки, не обёртки.
final class TestDatabase {
    private var handle: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init() throws {
        guard sqlite3_open(":memory:", &handle) == SQLITE_OK else {
            throw TestError.message("не удалось создать базу в памяти")
        }
        try execute("""
            CREATE TABLE case_records (id TEXT PRIMARY KEY, workspace_root_id TEXT, root_path TEXT);
            CREATE TABLE documents_catalog (
                id TEXT PRIMARY KEY, case_id TEXT, root_folder_path TEXT,
                folder_path TEXT, relative_path TEXT, file_name TEXT,
                document_type TEXT, is_external INTEGER DEFAULT 0,
                file_name_lower TEXT, relative_path_lower TEXT, folder_path_lower TEXT
            );
            CREATE TABLE document_text_variants (
                id TEXT PRIMARY KEY, document_id TEXT, case_id TEXT,
                variant_type TEXT, text_content TEXT
            );
            CREATE VIRTUAL TABLE document_text_variants_fts USING fts5(
                variant_id UNINDEXED, document_id UNINDEXED, case_id UNINDEXED,
                variant_type UNINDEXED, root_folder_path UNINDEXED,
                folder_path UNINDEXED, relative_path UNINDEXED,
                file_name_norm, text_content_norm,
                tokenize = 'unicode61 remove_diacritics 2'
            );
        """)
    }

    deinit { sqlite3_close(handle) }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "неизвестная ошибка"
            throw TestError.message("SQL: \(message)")
        }
    }

    func addCase(id: String, workspaceRootId: String, rootPath: String) throws {
        try run(
            "INSERT INTO case_records (id, workspace_root_id, root_path) VALUES (?, ?, ?)",
            [id, workspaceRootId, rootPath]
        )
    }

    /// Добавляет документ вместе с вариантом текста и записью в поисковом индексе.
    func addDocument(
        id: String,
        caseId: String,
        rootFolderPath: String,
        folderPath: String,
        relativePath: String,
        fileName: String,
        text: String
    ) throws {
        try run("""
            INSERT INTO documents_catalog
                (id, case_id, root_folder_path, folder_path, relative_path, file_name,
                 document_type, is_external, file_name_lower, relative_path_lower, folder_path_lower)
            VALUES (?, ?, ?, ?, ?, ?, NULL, 0, ?, ?, ?)
        """, [id, caseId, rootFolderPath, folderPath, relativePath, fileName,
              fileName.lowercased(), relativePath.lowercased(), folderPath.lowercased()])

        let variantId = "v-" + id
        try run(
            "INSERT INTO document_text_variants (id, document_id, case_id, variant_type, text_content) VALUES (?, ?, ?, 'original', ?)",
            [variantId, id, caseId, text]
        )
        try run("""
            INSERT INTO document_text_variants_fts
                (variant_id, document_id, case_id, variant_type, root_folder_path,
                 folder_path, relative_path, file_name_norm, text_content_norm)
            VALUES (?, ?, ?, 'original', ?, ?, ?, ?, ?)
        """, [variantId, id, caseId, rootFolderPath, folderPath, relativePath,
              RussianTextNormalizer.normalizeForIndex(fileName),
              RussianTextNormalizer.normalizeForIndex(text)])
    }

    func run(_ sql: String, _ bindings: [String]) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw TestError.message("prepare: \(String(cString: sqlite3_errmsg(handle)))")
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in bindings.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw TestError.message("step: \(String(cString: sqlite3_errmsg(handle)))")
        }
    }

    func scalarInt(_ sql: String) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw TestError.message("prepare scalar: \(String(cString: sqlite3_errmsg(handle)))")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw TestError.message("scalar не вернул строку")
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func scalarTwoInts(_ sql: String, _ bindings: [String]) throws -> (Int, Int) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw TestError.message("prepare two-ints: \(String(cString: sqlite3_errmsg(handle)))")
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in bindings.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient)
        }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw TestError.message("two-ints не вернул строку")
        }
        return (
            Int(sqlite3_column_int64(statement, 0)),
            Int(sqlite3_column_int64(statement, 1))
        )
    }

    /// Пути документов, найденных запросом, в порядке ранжирования.
    func paths(_ statement: DocumentSearchQuery.Statement) throws -> [String] {
        var handleStatement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, statement.sql, -1, &handleStatement, nil) == SQLITE_OK else {
            throw TestError.message("prepare: \(String(cString: sqlite3_errmsg(handle)))")
        }
        defer { sqlite3_finalize(handleStatement) }
        for (index, value) in statement.bindings.enumerated() {
            sqlite3_bind_text(handleStatement, Int32(index + 1), value, -1, transient)
        }
        var result: [String] = []
        while sqlite3_step(handleStatement) == SQLITE_ROW {
            if let text = sqlite3_column_text(handleStatement, 5) {
                result.append(String(cString: text))
            }
        }
        return result
    }
}

enum TestError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self { case .message(let text): return text }
    }
}
