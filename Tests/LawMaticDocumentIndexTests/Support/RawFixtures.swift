import Foundation
import SQLite
@testable import LawMaticDocumentIndex

/// Фикстуры прямым SQL — для тестов слоёв, которым нужен каталог или тексты,
/// но которые не должны зависеть от API соседнего слоя store.
enum RawFixtures {
    static let now = "2026-09-02T00:00:00Z"

    static func insertWorkspaceRoot(
        _ db: SQLite.Connection, id: String, name: String = "РАБОТА", localPath: String = "/Users/test/РАБОТА"
    ) throws {
        try db.run(
            "INSERT INTO workspace_roots(id, name, local_path, owner_app, created_at_iso, updated_at_iso) VALUES (?, ?, ?, 'lawmatic-finder', ?, ?)",
            id, name, localPath, now, now
        )
        try db.run(
            "INSERT INTO folders(workspace_root_id, parent_id, relative_path, depth) VALUES (?, NULL, '', 0)",
            id
        )
    }

    /// Создаёт цепочку папок и возвращает id последней.
    @discardableResult
    static func ensureFolder(_ db: SQLite.Connection, workspaceRootId: String, relativePath: String) throws -> Int64 {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var parentId = try folderId(db, workspaceRootId: workspaceRootId, relativePath: "")!
        var path = ""
        for (index, component) in components.enumerated() {
            path = path.isEmpty ? component : path + "/" + component
            if let existing = try folderId(db, workspaceRootId: workspaceRootId, relativePath: path) {
                parentId = existing
                continue
            }
            try db.run(
                "INSERT INTO folders(workspace_root_id, parent_id, relative_path, depth) VALUES (?, ?, ?, ?)",
                workspaceRootId, parentId, path, Int64(index + 1)
            )
            parentId = db.lastInsertRowid
        }
        return parentId
    }

    static func folderId(_ db: SQLite.Connection, workspaceRootId: String, relativePath: String) throws -> Int64? {
        for row in try db.prepare(
            "SELECT id FROM folders WHERE workspace_root_id = ? AND relative_path = ?", workspaceRootId, relativePath
        ) {
            return row[0] as? Int64
        }
        return nil
    }

    @discardableResult
    static func insertCase(
        _ db: SQLite.Connection, id: String, workspaceRootId: String, rootFolderPath: String, title: String
    ) throws -> Int64 {
        let folderId = try ensureFolder(db, workspaceRootId: workspaceRootId, relativePath: rootFolderPath)
        try db.run(
            "INSERT INTO cases(id, workspace_root_id, root_folder_id, title, created_at_iso, updated_at_iso) VALUES (?, ?, ?, ?, ?, ?)",
            id, workspaceRootId, folderId, title, now, now
        )
        return folderId
    }

    /// Документ рабочей папки; папка создаётся по родительскому каталогу пути.
    @discardableResult
    static func insertWorkspaceDocument(
        _ db: SQLite.Connection,
        id: String,
        workspaceRootId: String,
        relativePath: String,
        caseId: String? = nil,
        fileHash: String? = nil
    ) throws -> Int64 {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let fileName = components.last ?? relativePath
        let folderPath = components.dropLast().joined(separator: "/")
        let folderId = try ensureFolder(db, workspaceRootId: workspaceRootId, relativePath: folderPath)
        try db.run(
            """
            INSERT INTO documents(id, location_kind, workspace_root_id, folder_id, case_id, relative_path, file_name, file_name_lower,
                file_extension, file_size, file_modified_iso, file_hash, created_by_app, created_at_iso, updated_at_iso)
            VALUES (?, 'workspace', ?, ?, ?, ?, ?, ?, ?, 1024, ?, ?, 'lawmatic-finder', ?, ?)
            """,
            id, workspaceRootId, folderId, caseId, relativePath, fileName, fileName.lowercased(),
            (fileName as NSString).pathExtension.lowercased(), now, fileHash, now, now
        )
        let rowid = db.lastInsertRowid
        let path = relativePath
        try DocumentIndexStore.refreshDocumentsFTS(db, rowid: rowid,
            fileName: (path as NSString).lastPathComponent, pathForIndex: path)
        return rowid
    }

    @discardableResult
    static func insertExternalDocument(_ db: SQLite.Connection, id: String, absolutePath: String) throws -> Int64 {
        let url = URL(fileURLWithPath: absolutePath)
        try db.run(
            """
            INSERT INTO documents(id, location_kind, absolute_path, file_name, file_name_lower, file_extension,
                file_size, file_modified_iso, created_by_app, created_at_iso, updated_at_iso)
            VALUES (?, 'external', ?, ?, ?, ?, 1024, ?, 'lawmatic-finder', ?, ?)
            """,
            id, absolutePath, url.lastPathComponent, url.lastPathComponent.lowercased(),
            url.pathExtension.lowercased(), now, now, now
        )
        let rowid = db.lastInsertRowid
        try DocumentIndexStore.refreshDocumentsFTS(db, rowid: rowid,
            fileName: url.lastPathComponent, pathForIndex: absolutePath)
        return rowid
    }

    /// Текст с чанками и FTS — так же, как это сделает store: чанкер и нормализатор те же.
    @discardableResult
    static func insertText(_ db: SQLite.Connection, hash: String, content: String) throws -> [Int64] {
        try db.run(
            "INSERT INTO texts(text_hash, content, utf16_length, language_code, created_at_iso) VALUES (?, ?, ?, 'ru', ?)",
            hash, content, Int64((content as NSString).length), now
        )
        var rowids: [Int64] = []
        for chunk in SearchChunker.chunks(from: content) {
            try db.run(
                "INSERT INTO chunks(id, text_hash, chunk_index, utf16_start, utf16_end) VALUES (?, ?, ?, ?, ?)",
                ChunkRecord.makeId(textHash: hash, chunkIndex: chunk.chunkIndex), hash,
                Int64(chunk.chunkIndex), Int64(chunk.utf16Start), Int64(chunk.utf16End)
            )
            let rowid = db.lastInsertRowid
            try db.run(
                "INSERT INTO chunk_fts(rowid, file_name_norm, content_norm) VALUES (?, ?, ?)",
                rowid, "", RussianTextNormalizer.normalizeForIndex(chunk.content)
            )
            rowids.append(rowid)
        }
        return rowids
    }

    static func insertVariant(
        _ db: SQLite.Connection, documentId: String, textHash: String, type: String = "original"
    ) throws {
        try db.run(
            """
            INSERT INTO text_variants(id, document_id, variant_type, text_hash, is_current, created_at_iso, updated_at_iso)
            VALUES (?, ?, ?, ?, 1, ?, ?)
            """,
            UUID().uuidString, documentId, type, textHash, now, now
        )
    }
}
