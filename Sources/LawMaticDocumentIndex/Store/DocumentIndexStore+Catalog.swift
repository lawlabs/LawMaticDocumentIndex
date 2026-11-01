import Foundation
import SQLite

extension DocumentIndexStore {

    // MARK: - Рабочие корни

    @discardableResult
    public func registerWorkspaceRoot(
        id: String? = nil,
        name: String,
        localPath: String,
        ownerApp: String? = nil
    ) throws -> WorkspaceRootRecord {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw DocumentIndexError.invalidArgument("пустое имя рабочего корня")
        }
        let path = Self.normalizeLocalPath(localPath)
        guard !path.isEmpty else {
            throw DocumentIndexError.invalidArgument("пустой путь рабочего корня")
        }
        let writerAppId = ownerApp ?? self.writerAppId
        let existingId = id ?? localWorkspacePaths.first(where: { $0.value == path })?.key
        let record = try write { db in
            try Self.registerWorkspaceRoot(
                db, id: existingId, name: trimmedName, localPath: "", ownerApp: writerAppId
            )
        }
        localWorkspacePaths[record.id] = path
        return locallyBound(record)
    }

    /// Registers shared identity when the original files are unavailable on this computer.
    @discardableResult
    public func registerUnboundWorkspaceRoot(id: String, name: String) throws -> WorkspaceRootRecord {
        guard !id.isEmpty, !name.isEmpty else { throw DocumentIndexError.invalidArgument("empty root identity") }
        let record = try write { db in
            try Self.registerWorkspaceRoot(db, id: id, name: name, localPath: "", ownerApp: writerAppId)
        }
        return locallyBound(record)
    }

    /// A reader can bind the same root to a different directory without writing SQLite.
    public func setWorkspacePaths(_ paths: [String: String]) throws {
        var normalized: [String: String] = [:]
        for (id, path) in paths {
            guard path.hasPrefix("/"), !id.isEmpty else {
                throw DocumentIndexError.invalidArgument("invalid local workspace binding")
            }
            normalized[id] = Self.normalizeLocalPath(path)
        }
        localWorkspacePaths = normalized
    }

    func locallyBound(_ record: WorkspaceRootRecord) -> WorkspaceRootRecord {
        WorkspaceRootRecord(id: record.id, name: record.name,
            localPath: localWorkspacePaths[record.id] ?? "", ownerApp: record.ownerApp,
            createdAt: record.createdAt, updatedAt: record.updatedAt)
    }

    public func workspaceRoots() throws -> [WorkspaceRootRecord] {
        try Self.workspaceRoots(try db()).map(locallyBound)
    }

    public func workspaceRoot(id: String) throws -> WorkspaceRootRecord? {
        try Self.workspaceRoot(try db(), id: id).map(locallyBound)
    }

    public func workspaceRoot(localPath: String) throws -> WorkspaceRootRecord? {
        guard let id = localWorkspacePaths.first(where: {
            $0.value == Self.normalizeLocalPath(localPath)
        })?.key else { return nil }
        return try workspaceRoot(id: id)
    }

    public func deleteWorkspaceRoot(id: String) throws {
        try write { db in
            let hashes = try Self.currentTextHashes(db, workspaceRootId: id)
            try Self.deleteWorkspaceRoot(db, id: id)
            try Self.rebuildChunkFTSIfLinked(db, textHashes: hashes)
        }
        // Сборка осиротевших текстов — отдельная транзакция: `write` не вкладывается.
        try collectOrphanTexts()
    }

    // MARK: - Папки

    @discardableResult
    public func ensureFolder(workspaceRootId: String, relativePath: String) throws -> FolderRecord {
        try write { db in
            try Self.ensureFolder(db, workspaceRootId: workspaceRootId, relativePath: relativePath)
        }
    }

    public func folder(workspaceRootId: String, relativePath: String) throws -> FolderRecord? {
        try Self.folder(
            try db(),
            workspaceRootId: workspaceRootId,
            relativePath: SearchScope.canonicalFolderPath(relativePath)
        )
    }

    public func folder(id: Int64) throws -> FolderRecord? {
        try Self.folder(try db(), id: id)
    }

    public func childFolders(of folderId: Int64) throws -> [FolderRecord] {
        try Self.childFolders(try db(), of: folderId)
    }

    public func ancestorFolders(of folderId: Int64) throws -> [FolderRecord] {
        try Self.ancestorFolders(try db(), of: folderId)
    }

    // MARK: - Дела

    @discardableResult
    public func upsertCase(
        id: String? = nil,
        workspaceRootId: String,
        rootFolderPath: String,
        title: String
    ) throws -> CaseRecord {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw DocumentIndexError.invalidArgument("пустое название дела")
        }
        return try write { db in
            try Self.upsertCase(
                db,
                id: id,
                workspaceRootId: workspaceRootId,
                rootFolderPath: rootFolderPath,
                title: trimmedTitle
            )
        }
    }

    public func cases(workspaceRootId: String? = nil) throws -> [CaseRecord] {
        try Self.cases(try db(), workspaceRootId: workspaceRootId)
    }

    public func caseRecord(id: String) throws -> CaseRecord? {
        try Self.caseRecord(try db(), id: id)
    }

    /// Дело, корень которого совпадает с папкой. Не поднимается к предку.
    public func caseAt(workspaceRootId: String, rootFolderPath: String) throws -> CaseRecord? {
        try Self.caseAt(try db(), workspaceRootId: workspaceRootId, rootFolderPath: rootFolderPath)
    }

    public func caseContaining(folderId: Int64) throws -> CaseRecord? {
        try Self.caseContaining(try db(), folderId: folderId)
    }

    public func deleteCase(id: String) throws {
        try write { db in
            try Self.deleteCase(db, id: id)
        }
    }

    public func reassignCases(workspaceRootId: String) throws {
        try write { db in
            try Self.reassignCases(db, workspaceRootId: workspaceRootId)
        }
    }

    // MARK: - Документы

    @discardableResult
    public func upsertWorkspaceDocument(
        workspaceRootId: String,
        relativePath: String,
        fileSize: Int64,
        fileModifiedAt: Date,
        fileHash: String?,
        createdByApp: String? = nil
    ) throws -> IndexedDocument {
        let createdByApp = createdByApp ?? writerAppId
        return try write { db in
            let parsed = try Self.parseWorkspaceFilePath(relativePath)
            let previousName = try Self.document(
                db, workspaceRootId: workspaceRootId, relativePath: parsed.relativePath
            )?.fileName
            let updated = try Self.upsertWorkspaceDocument(
                db,
                workspaceRootId: workspaceRootId,
                relativePath: relativePath,
                fileSize: fileSize,
                fileModifiedAt: fileModifiedAt,
                fileHash: fileHash,
                createdByApp: createdByApp
            )
            if let previousName, previousName != updated.fileName {
                try Self.rebuildChunkFTSForDocument(db, documentId: updated.id)
            }
            return updated
        }
    }

    @discardableResult
    public func upsertExternalDocument(
        absolutePath: String,
        fileSize: Int64,
        fileModifiedAt: Date,
        fileHash: String?,
        createdByApp: String? = nil
    ) throws -> IndexedDocument {
        let createdByApp = createdByApp ?? writerAppId
        return try write { db in
            let path = Self.normalizeLocalPath(absolutePath)
            let previousName = try Self.document(db, absolutePath: path)?.fileName
            let updated = try Self.upsertExternalDocument(
                db,
                absolutePath: absolutePath,
                fileSize: fileSize,
                fileModifiedAt: fileModifiedAt,
                fileHash: fileHash,
                createdByApp: createdByApp
            )
            if let previousName, previousName != updated.fileName {
                try Self.rebuildChunkFTSForDocument(db, documentId: updated.id)
            }
            return updated
        }
    }

    public func document(id: String) throws -> IndexedDocument? {
        try Self.document(try db(), id: id)
    }

    public func document(workspaceRootId: String, relativePath: String) throws -> IndexedDocument? {
        try Self.document(
            try db(),
            workspaceRootId: workspaceRootId,
            relativePath: SearchScope.canonicalFolderPath(relativePath)
        )
    }

    public func document(absolutePath: String) throws -> IndexedDocument? {
        try Self.document(try db(), absolutePath: Self.normalizeLocalPath(absolutePath))
    }

    public func documents(in scope: SearchScope, limit: Int? = nil, offset: Int = 0) throws -> [IndexedDocument] {
        let db = try db()
        let fragment = Self.catalogDocumentsSQL(scope: scope, limit: limit, offset: offset,
            includeCaseLinks: try currentCapabilities().supportsExplicitCaseDocuments)
        return try Self.allDocuments(db, fragment.sql, Self.boxed(fragment.bindings))
    }

    public func documentCount(in scope: SearchScope) throws -> Int {
        let db = try db()
        let fragment = ScopeSQL(scope: scope, includeCaseLinks: try currentCapabilities().supportsExplicitCaseDocuments)
        let sql = fragment.withClause + "SELECT COUNT(*) FROM documents d WHERE \(fragment.predicate)"
        let value = try db.scalar(sql, Self.boxed(fragment.bindings))
        if let int64 = value as? Int64 { return Int(int64) }
        if let int = value as? Int { return int }
        return 0
    }

    public func documents(fileHash: String) throws -> [IndexedDocument] {
        try Self.allDocuments(
            try db(),
            "SELECT \(Self.documentColumnsUnaliased) FROM documents WHERE file_hash = ? ORDER BY COALESCE(relative_path, absolute_path)",
            [fileHash]
        )
    }

    public func fileURL(for document: IndexedDocument) throws -> URL? {
        let resolved = try resolvedLocation(for: document)
        return resolved.isOriginalAvailable ? resolved.fileURL : nil
    }

    /// Координата для UI: текст индекса доступен всегда, file URL — только при подключённом корне.
    public func resolvedLocation(for document: IndexedDocument) throws -> (fileURL: URL, isOriginalAvailable: Bool) {
        switch document.locationKind {
        case .workspace:
            let relative = document.relativePath ?? ""
            guard let rootId = document.workspaceRootId else {
                return (DocumentIndexPath.unavailableURL(workspaceRootId: "unknown", relativePath: relative), false)
            }
            if let root = try workspaceRoot(id: rootId), !root.localPath.isEmpty {
                return (Self.fileURL(localPath: root.localPath, relativePath: relative), true)
            }
            return (DocumentIndexPath.unavailableURL(workspaceRootId: rootId, relativePath: relative), false)
        case .external:
            guard let path = document.absolutePath, !path.isEmpty else {
                return (DocumentIndexPath.unavailableURL(workspaceRootId: "external", relativePath: document.fileName), false)
            }
            return (URL(fileURLWithPath: path), true)
        }
    }

    public func moveDocument(id: String, toWorkspaceRootId: String, relativePath: String, mutationGuard: DocumentIndexMutationGuard? = nil) throws -> IndexedDocument {
        try write { db in
            try validateMutation(mutationGuard, db: db)
            let previousName = try Self.document(db, id: id)?.fileName
            let updated = try Self.moveDocument(
                db, id: id, toWorkspaceRootId: toWorkspaceRootId, relativePath: relativePath
            )
            if let previousName, previousName != updated.fileName {
                try Self.rebuildChunkFTSForDocument(db, documentId: updated.id)
            }
            return updated
        }
    }

    public func deleteDocument(id: String) throws {
        try write { db in
            let hashes = try Self.currentTextHashes(db, documentId: id)
            try Self.deleteDocument(db, id: id)
            try Self.rebuildChunkFTSIfLinked(db, textHashes: hashes)
        }
        try collectOrphanTexts()
    }

    public func searchDocumentsByName(
        query: String,
        scope: SearchScope,
        limit: Int = 50
    ) throws -> [IndexedDocument] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let cappedLimit = max(limit, 0)
        let db = try db()
        let stems = RussianTextNormalizer.queryStems(from: trimmed)

        if !stems.isEmpty {
            let allWords = DocumentSearchQuery.matchExpression(stems: stems, mode: .allWords)
            if !allWords.isEmpty {
                let found = try Self.searchDocumentsFTS(db, match: allWords, scope: scope, limit: cappedLimit, includeCaseLinks: try currentCapabilities().supportsExplicitCaseDocuments)
                if !found.isEmpty { return found }
            }
            let anyWord = DocumentSearchQuery.matchExpression(stems: stems, mode: .anyWord)
            if !anyWord.isEmpty {
                let found = try Self.searchDocumentsFTS(db, match: anyWord, scope: scope, limit: cappedLimit, includeCaseLinks: try currentCapabilities().supportsExplicitCaseDocuments)
                if !found.isEmpty { return found }
            }
        }

        return try Self.searchDocumentsLike(db, query: trimmed, scope: scope, limit: cappedLimit, includeCaseLinks: try currentCapabilities().supportsExplicitCaseDocuments)
    }

    /// Тот же SELECT, что `documents(in:)` — для `EXPLAIN QUERY PLAN` в тестах.
    static func catalogDocumentsSQL(
        scope: SearchScope,
        limit: Int? = nil,
        offset: Int = 0, includeCaseLinks: Bool = false
    ) -> (sql: String, bindings: [Binding]) {
        let fragment = ScopeSQL(scope: scope, includeCaseLinks: includeCaseLinks)
        var sql = fragment.withClause + """
            SELECT \(documentColumns)
            FROM documents d
            WHERE \(fragment.predicate)
            ORDER BY COALESCE(d.relative_path, d.absolute_path)
            """
        sql += Self.limitSQL(limit: limit, offset: offset)
        return (sql, fragment.bindings)
    }

    static func boxed(_ bindings: [Binding]) -> [Binding?] {
        bindings.map { $0 as Binding? }
    }
}

// MARK: - Разбор и SQL

extension DocumentIndexStore {

    static let documentColumns = """
        d.rowid, d.id, d.location_kind, d.workspace_root_id, d.folder_id, d.case_id, \
        d.relative_path, d.absolute_path, d.file_name, d.file_extension, \
        d.file_size, d.file_modified_iso, d.file_hash, d.created_by_app, \
        d.created_at_iso, d.updated_at_iso
        """

    static let documentColumnsUnaliased = """
        rowid, id, location_kind, workspace_root_id, folder_id, case_id, \
        relative_path, absolute_path, file_name, file_extension, \
        file_size, file_modified_iso, file_hash, created_by_app, \
        created_at_iso, updated_at_iso
        """

    static func normalizeLocalPath(_ path: String) -> String {
        var result = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.count > 1, result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }

    static func fileURL(localPath: String, relativePath: String) -> URL {
        var url = URL(fileURLWithPath: localPath, isDirectory: true)
        for component in relativePath.split(separator: "/", omittingEmptySubsequences: true) {
            url.append(path: String(component))
        }
        return url
    }

    static func limitSQL(limit: Int?, offset: Int) -> String {
        let safeOffset = max(offset, 0)
        if let limit {
            return " LIMIT \(max(limit, 0)) OFFSET \(safeOffset)"
        }
        if safeOffset > 0 {
            return " LIMIT -1 OFFSET \(safeOffset)"
        }
        return ""
    }

    static func requireDate(_ reader: RowReader, _ index: Int, field: String) throws -> Date {
        guard let date = reader.date(index) else {
            throw DocumentIndexError.invalidArgument("некорректная дата \(field)")
        }
        return date
    }

    static func parseWorkspaceRoot(_ reader: RowReader) throws -> WorkspaceRootRecord {
        guard let id = reader.string(0), let name = reader.string(1),
              let localPath = reader.string(2), let ownerApp = reader.string(3) else {
            throw DocumentIndexError.invalidArgument("неполная строка рабочего корня")
        }
        return WorkspaceRootRecord(
            id: id,
            name: name,
            localPath: localPath,
            ownerApp: ownerApp,
            createdAt: try requireDate(reader, 4, field: "created_at"),
            updatedAt: try requireDate(reader, 5, field: "updated_at")
        )
    }

    static func parseFolder(_ reader: RowReader) throws -> FolderRecord {
        guard let id = reader.int64(0), let workspaceRootId = reader.string(1),
              let relativePath = reader.string(3), let depth = reader.int(4) else {
            throw DocumentIndexError.invalidArgument("неполная строка папки")
        }
        return FolderRecord(
            id: id,
            workspaceRootId: workspaceRootId,
            parentId: reader.int64(2),
            relativePath: relativePath,
            depth: depth
        )
    }

    static func parseCase(_ reader: RowReader) throws -> CaseRecord {
        guard let id = reader.string(0), let workspaceRootId = reader.string(1),
              let rootFolderId = reader.int64(2), let title = reader.string(3) else {
            throw DocumentIndexError.invalidArgument("неполная строка дела")
        }
        return CaseRecord(
            id: id,
            workspaceRootId: workspaceRootId,
            rootFolderId: rootFolderId,
            title: title,
            createdAt: try requireDate(reader, 4, field: "created_at"),
            updatedAt: try requireDate(reader, 5, field: "updated_at")
        )
    }

    static func parseDocument(_ reader: RowReader) throws -> IndexedDocument {
        guard let rowid = reader.int64(0), let id = reader.string(1),
              let kindRaw = reader.string(2),
              let kind = DocumentLocationKind(rawValue: kindRaw),
              let fileName = reader.string(8),
              let fileExtension = reader.string(9),
              let fileSize = reader.int64(10),
              let createdByApp = reader.string(13) else {
            throw DocumentIndexError.invalidArgument("неполная строка документа")
        }
        return IndexedDocument(
            rowid: rowid,
            id: id,
            locationKind: kind,
            workspaceRootId: reader.string(3),
            folderId: reader.int64(4),
            caseId: reader.string(5),
            relativePath: reader.string(6),
            absolutePath: reader.string(7),
            fileName: fileName,
            fileExtension: fileExtension,
            fileSize: fileSize,
            fileModifiedAt: try requireDate(reader, 11, field: "file_modified_at"),
            fileHash: reader.string(12),
            createdByApp: createdByApp,
            createdAt: try requireDate(reader, 14, field: "created_at"),
            updatedAt: try requireDate(reader, 15, field: "updated_at")
        )
    }

    static func firstRow<T>(
        _ db: SQLite.Connection,
        _ sql: String,
        _ bindings: [Binding?],
        parse: (RowReader) throws -> T
    ) throws -> T? {
        for row in try db.prepare(sql, bindings) {
            return try parse(RowReader(row))
        }
        return nil
    }

    static func allRows<T>(
        _ db: SQLite.Connection,
        _ sql: String,
        _ bindings: [Binding?],
        parse: (RowReader) throws -> T
    ) throws -> [T] {
        var result: [T] = []
        for row in try db.prepare(sql, bindings) {
            result.append(try parse(RowReader(row)))
        }
        return result
    }

    static func firstDocument(_ db: SQLite.Connection, _ sql: String, _ bindings: [Binding?]) throws -> IndexedDocument? {
        try firstRow(db, sql, bindings, parse: parseDocument)
    }

    static func allDocuments(_ db: SQLite.Connection, _ sql: String, _ bindings: [Binding?]) throws -> [IndexedDocument] {
        try allRows(db, sql, bindings, parse: parseDocument)
    }
}

// MARK: - Запись каталога

extension DocumentIndexStore {

    static func workspaceRoots(_ db: SQLite.Connection) throws -> [WorkspaceRootRecord] {
        try allRows(
            db,
            """
            SELECT id, name, local_path, owner_app, created_at_iso, updated_at_iso
            FROM workspace_roots
            ORDER BY name COLLATE NOCASE, local_path
            """,
            [],
            parse: parseWorkspaceRoot
        )
    }

    static func workspaceRoot(_ db: SQLite.Connection, id: String) throws -> WorkspaceRootRecord? {
        try firstRow(
            db,
            """
            SELECT id, name, local_path, owner_app, created_at_iso, updated_at_iso
            FROM workspace_roots WHERE id = ?
            """,
            [id],
            parse: parseWorkspaceRoot
        )
    }

    static func workspaceRoot(_ db: SQLite.Connection, localPath: String) throws -> WorkspaceRootRecord? {
        try firstRow(
            db,
            """
            SELECT id, name, local_path, owner_app, created_at_iso, updated_at_iso
            FROM workspace_roots WHERE local_path = ?
            """,
            [localPath],
            parse: parseWorkspaceRoot
        )
    }

    static func registerWorkspaceRoot(
        _ db: SQLite.Connection,
        id: String?,
        name: String,
        localPath: String,
        ownerApp: String
    ) throws -> WorkspaceRootRecord {
        let now = iso(Date())
        if let id, let existing = try workspaceRoot(db, id: id) {
            try db.run(
                "UPDATE workspace_roots SET name = ?, local_path = '', updated_at_iso = ? WHERE id = ?",
                name, now, existing.id
            )
            guard let updated = try workspaceRoot(db, id: existing.id) else {
                throw DocumentIndexError.notFound("рабочий корень \(existing.id)")
            }
            return updated
        }

        let newId = (id?.isEmpty == false) ? id! : UUID().uuidString
        try db.run(
            """
            INSERT INTO workspace_roots(id, name, local_path, owner_app, created_at_iso, updated_at_iso)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            newId, name, localPath, ownerApp, now, now
        )
        try db.run(
            "INSERT INTO folders(workspace_root_id, parent_id, relative_path, depth) VALUES (?, NULL, '', 0)",
            newId
        )
        guard let created = try workspaceRoot(db, id: newId) else {
            throw DocumentIndexError.notFound("рабочий корень \(newId)")
        }
        return created
    }

    static func deleteWorkspaceRoot(_ db: SQLite.Connection, id: String) throws {
        guard try workspaceRoot(db, id: id) != nil else {
            throw DocumentIndexError.notFound("рабочий корень \(id)")
        }
        // contentless FTS удаляется только по rowid, до каскада по documents.
        try db.run(
            "DELETE FROM documents_fts WHERE rowid IN (SELECT rowid FROM documents WHERE workspace_root_id = ?)",
            id
        )
        try db.run("DELETE FROM workspace_roots WHERE id = ?", id)
    }

    static func folder(_ db: SQLite.Connection, id: Int64) throws -> FolderRecord? {
        try firstRow(
            db,
            "SELECT id, workspace_root_id, parent_id, relative_path, depth FROM folders WHERE id = ?",
            [id],
            parse: parseFolder
        )
    }

    static func folder(
        _ db: SQLite.Connection,
        workspaceRootId: String,
        relativePath: String
    ) throws -> FolderRecord? {
        try firstRow(
            db,
            """
            SELECT id, workspace_root_id, parent_id, relative_path, depth
            FROM folders WHERE workspace_root_id = ? AND relative_path = ?
            """,
            [workspaceRootId, relativePath],
            parse: parseFolder
        )
    }

    static func childFolders(_ db: SQLite.Connection, of folderId: Int64) throws -> [FolderRecord] {
        try allRows(
            db,
            """
            SELECT id, workspace_root_id, parent_id, relative_path, depth
            FROM folders WHERE parent_id = ? ORDER BY relative_path
            """,
            [folderId],
            parse: parseFolder
        )
    }

    static func ancestorFolders(_ db: SQLite.Connection, of folderId: Int64) throws -> [FolderRecord] {
        try allRows(
            db,
            """
            WITH RECURSIVE walk(id, workspace_root_id, parent_id, relative_path, depth, step) AS (
                SELECT f.id, f.workspace_root_id, f.parent_id, f.relative_path, f.depth, 0
                FROM folders start
                JOIN folders f ON f.id = start.parent_id
                WHERE start.id = ?
                UNION ALL
                SELECT f.id, f.workspace_root_id, f.parent_id, f.relative_path, f.depth, w.step + 1
                FROM walk w
                JOIN folders f ON f.id = w.parent_id
            )
            SELECT id, workspace_root_id, parent_id, relative_path, depth
            FROM walk
            ORDER BY step
            """,
            [folderId],
            parse: parseFolder
        )
    }

    static func ensureFolder(
        _ db: SQLite.Connection,
        workspaceRootId: String,
        relativePath: String
    ) throws -> FolderRecord {
        guard try workspaceRoot(db, id: workspaceRootId) != nil else {
            throw DocumentIndexError.notFound("рабочий корень \(workspaceRootId)")
        }
        let canonical = try SearchScope.validatedRelativePath(relativePath)
        if let existing = try folder(db, workspaceRootId: workspaceRootId, relativePath: canonical) {
            return existing
        }
        guard let rootFolder = try folder(db, workspaceRootId: workspaceRootId, relativePath: "") else {
            throw DocumentIndexError.notFound("корневая папка \(workspaceRootId)")
        }
        if canonical.isEmpty { return rootFolder }

        var parent = rootFolder
        var currentPath = ""
        let components = canonical.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        for (index, component) in components.enumerated() {
            currentPath = currentPath.isEmpty ? component : currentPath + "/" + component
            if let existing = try folder(db, workspaceRootId: workspaceRootId, relativePath: currentPath) {
                parent = existing
                continue
            }
            try db.run(
                "INSERT INTO folders(workspace_root_id, parent_id, relative_path, depth) VALUES (?, ?, ?, ?)",
                [workspaceRootId, parent.id, currentPath, Int64(index + 1)]
            )
            guard let created = try folder(db, workspaceRootId: workspaceRootId, relativePath: currentPath) else {
                throw DocumentIndexError.notFound("папка \(currentPath)")
            }
            parent = created
        }
        return parent
    }

    static func cases(_ db: SQLite.Connection, workspaceRootId: String?) throws -> [CaseRecord] {
        let sql: String
        let bindings: [Binding?]
        if let workspaceRootId {
            sql = """
                SELECT id, workspace_root_id, root_folder_id, title, created_at_iso, updated_at_iso
                FROM cases WHERE workspace_root_id = ? ORDER BY title COLLATE NOCASE
                """
            bindings = [workspaceRootId]
        } else {
            sql = """
                SELECT id, workspace_root_id, root_folder_id, title, created_at_iso, updated_at_iso
                FROM cases ORDER BY title COLLATE NOCASE
                """
            bindings = []
        }
        return try allRows(db, sql, bindings, parse: parseCase)
    }

    static func caseRecord(_ db: SQLite.Connection, id: String) throws -> CaseRecord? {
        try firstRow(
            db,
            """
            SELECT id, workspace_root_id, root_folder_id, title, created_at_iso, updated_at_iso
            FROM cases WHERE id = ?
            """,
            [id],
            parse: parseCase
        )
    }

    static func caseAt(
        _ db: SQLite.Connection,
        workspaceRootId: String,
        rootFolderPath: String
    ) throws -> CaseRecord? {
        guard let folder = try folder(
            db,
            workspaceRootId: workspaceRootId,
            relativePath: SearchScope.canonicalFolderPath(rootFolderPath)
        ) else { return nil }
        return try firstRow(
            db,
            """
            SELECT id, workspace_root_id, root_folder_id, title, created_at_iso, updated_at_iso
            FROM cases WHERE workspace_root_id = ? AND root_folder_id = ?
            """,
            [workspaceRootId, folder.id],
            parse: parseCase
        )
    }

    static func caseContaining(_ db: SQLite.Connection, folderId: Int64) throws -> CaseRecord? {
        try firstRow(
            db,
            """
            WITH RECURSIVE walk(id, parent_id, depth) AS (
                SELECT id, parent_id, depth FROM folders WHERE id = ?
                UNION ALL
                SELECT f.id, f.parent_id, f.depth
                FROM folders f
                JOIN walk w ON f.id = w.parent_id
            )
            SELECT c.id, c.workspace_root_id, c.root_folder_id, c.title, c.created_at_iso, c.updated_at_iso
            FROM walk w
            JOIN cases c ON c.root_folder_id = w.id
            ORDER BY w.depth DESC
            LIMIT 1
            """,
            [folderId],
            parse: parseCase
        )
    }

    /// Один UPDATE: ближайшее дело-предок папки документа, включая саму папку.
    static func reassignCases(_ db: SQLite.Connection, workspaceRootId: String) throws {
        try db.run(
            """
            WITH RECURSIVE walk(folder_id, current_id, current_depth) AS (
                SELECT id, id, depth FROM folders WHERE workspace_root_id = ?
                UNION ALL
                SELECT w.folder_id, p.id, p.depth
                FROM walk w
                JOIN folders cur ON cur.id = w.current_id
                JOIN folders p ON p.id = cur.parent_id
            ),
            best AS (
                SELECT w.folder_id, MAX(w.current_depth) AS max_depth
                FROM walk w
                JOIN cases c ON c.root_folder_id = w.current_id
                GROUP BY w.folder_id
            ),
            nearest AS (
                SELECT w.folder_id, c.id AS case_id
                FROM walk w
                JOIN cases c ON c.root_folder_id = w.current_id
                JOIN best b ON b.folder_id = w.folder_id AND b.max_depth = w.current_depth
            )
            UPDATE documents
            SET case_id = (SELECT n.case_id FROM nearest n WHERE n.folder_id = documents.folder_id)
            WHERE workspace_root_id = ? AND location_kind = 'workspace'
            """,
            workspaceRootId, workspaceRootId
        )
    }

    static func upsertCase(
        _ db: SQLite.Connection,
        id: String?,
        workspaceRootId: String,
        rootFolderPath: String,
        title: String
    ) throws -> CaseRecord {
        let folder = try ensureFolder(db, workspaceRootId: workspaceRootId, relativePath: rootFolderPath)
        let now = iso(Date())
        if let existing = try firstRow(
            db,
            """
            SELECT id, workspace_root_id, root_folder_id, title, created_at_iso, updated_at_iso
            FROM cases WHERE workspace_root_id = ? AND root_folder_id = ?
            """,
            [workspaceRootId, folder.id],
            parse: parseCase
        ) {
            try db.run(
                "UPDATE cases SET title = ?, updated_at_iso = ? WHERE id = ?",
                title, now, existing.id
            )
            try reassignCases(db, workspaceRootId: workspaceRootId)
            guard let updated = try caseRecord(db, id: existing.id) else {
                throw DocumentIndexError.notFound("дело \(existing.id)")
            }
            return updated
        }

        let newId = (id?.isEmpty == false) ? id! : UUID().uuidString
        try db.run(
            """
            INSERT INTO cases(id, workspace_root_id, root_folder_id, title, created_at_iso, updated_at_iso)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            newId, workspaceRootId, folder.id, title, now, now
        )
        try reassignCases(db, workspaceRootId: workspaceRootId)
        guard let created = try caseRecord(db, id: newId) else {
            throw DocumentIndexError.notFound("дело \(newId)")
        }
        return created
    }

    static func deleteCase(_ db: SQLite.Connection, id: String) throws {
        guard let record = try caseRecord(db, id: id) else {
            throw DocumentIndexError.notFound("дело \(id)")
        }
        try db.run("DELETE FROM cases WHERE id = ?", id)
        try reassignCases(db, workspaceRootId: record.workspaceRootId)
    }

    static func document(_ db: SQLite.Connection, id: String) throws -> IndexedDocument? {
        try firstDocument(
            db,
            "SELECT \(documentColumnsUnaliased) FROM documents WHERE id = ?",
            [id]
        )
    }

    static func document(
        _ db: SQLite.Connection,
        workspaceRootId: String,
        relativePath: String
    ) throws -> IndexedDocument? {
        try firstDocument(
            db,
            """
            SELECT \(documentColumnsUnaliased) FROM documents
            WHERE location_kind = 'workspace' AND workspace_root_id = ? AND relative_path = ?
            """,
            [workspaceRootId, relativePath]
        )
    }

    static func document(_ db: SQLite.Connection, absolutePath: String) throws -> IndexedDocument? {
        try firstDocument(
            db,
            """
            SELECT \(documentColumnsUnaliased) FROM documents
            WHERE location_kind = 'external' AND absolute_path = ?
            """,
            [absolutePath]
        )
    }

    static func parseWorkspaceFilePath(_ relativePath: String) throws -> (relativePath: String, folderPath: String, fileName: String, fileExtension: String) {
        let canonical = try DocumentIndexPath.validateDocument(relativePath)
        let parts = canonical.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let fileName = parts.last, !fileName.isEmpty else {
            throw DocumentIndexError.invalidArgument("пустой путь документа")
        }
        return (
            relativePath: canonical,
            folderPath: parts.dropLast().joined(separator: "/"),
            fileName: fileName,
            fileExtension: (fileName as NSString).pathExtension.lowercased()
        )
    }

    static func refreshDocumentsFTS(
        _ db: SQLite.Connection,
        rowid: Int64,
        fileName: String,
        pathForIndex: String
    ) throws {
        try db.run("DELETE FROM documents_fts WHERE rowid = ?", rowid)
        try db.run(
            "INSERT INTO documents_fts(rowid, file_name_norm, relative_path_norm) VALUES (?, ?, ?)",
            rowid,
            RussianTextNormalizer.normalizeForIndex(fileName),
            RussianTextNormalizer.normalizeForIndex(pathForIndex)
        )
    }

    static func upsertWorkspaceDocument(
        _ db: SQLite.Connection,
        workspaceRootId: String,
        relativePath: String,
        fileSize: Int64,
        fileModifiedAt: Date,
        fileHash: String?,
        createdByApp: String
    ) throws -> IndexedDocument {
        let parsed = try parseWorkspaceFilePath(relativePath)
        let folder = try ensureFolder(db, workspaceRootId: workspaceRootId, relativePath: parsed.folderPath)
        let caseId = try caseContaining(db, folderId: folder.id)?.id
        let now = iso(Date())
        let modified = iso(fileModifiedAt)
        let fileNameLower = parsed.fileName.lowercased()

        if let existing = try document(db, workspaceRootId: workspaceRootId, relativePath: parsed.relativePath) {
            if existing.fileHash != fileHash || (fileHash == nil && (existing.fileSize != fileSize || existing.fileModifiedAt != fileModifiedAt)) {
                try invalidateCurrentText(db, documentId: existing.id)
                try setExtractionState(db, ExtractionState(documentId: existing.id, status: .pending))
            }
            try db.run(
                """
                UPDATE documents SET
                    folder_id = ?, case_id = ?, file_size = ?, file_modified_iso = ?,
                    file_hash = ?, updated_at_iso = ?
                WHERE id = ?
                """,
                [folder.id, caseId, fileSize, modified, fileHash, now, existing.id]
            )
            try refreshDocumentsFTS(
                db, rowid: existing.rowid, fileName: parsed.fileName, pathForIndex: parsed.relativePath
            )
            guard let updated = try document(db, id: existing.id) else {
                throw DocumentIndexError.notFound("документ \(existing.id)")
            }
            return updated
        }

        let newId = UUID().uuidString
        try db.run(
            """
            INSERT INTO documents(
                id, location_kind, workspace_root_id, folder_id, case_id, relative_path,
                file_name, file_name_lower, file_extension, file_size, file_modified_iso,
                file_hash, created_by_app, created_at_iso, updated_at_iso
            ) VALUES (?, 'workspace', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                newId, workspaceRootId, folder.id, caseId, parsed.relativePath,
                parsed.fileName, fileNameLower, parsed.fileExtension, fileSize, modified,
                fileHash, createdByApp, now, now,
            ]
        )
        guard let created = try document(db, id: newId) else {
            throw DocumentIndexError.notFound("документ \(newId)")
        }
        try refreshDocumentsFTS(
            db, rowid: created.rowid, fileName: parsed.fileName, pathForIndex: parsed.relativePath
        )
        return created
    }

    static func upsertExternalDocument(
        _ db: SQLite.Connection,
        absolutePath: String,
        fileSize: Int64,
        fileModifiedAt: Date,
        fileHash: String?,
        createdByApp: String
    ) throws -> IndexedDocument {
        let path = normalizeLocalPath(absolutePath)
        guard !path.isEmpty, path != "/" else {
            throw DocumentIndexError.invalidArgument("пустой абсолютный путь")
        }
        let fileName = URL(fileURLWithPath: path).lastPathComponent
        guard !fileName.isEmpty, fileName != "/" else {
            throw DocumentIndexError.invalidArgument("пустой абсолютный путь")
        }
        let fileExtension = (fileName as NSString).pathExtension.lowercased()
        let now = iso(Date())
        let modified = iso(fileModifiedAt)

        if let existing = try document(db, absolutePath: path) {
            if existing.fileHash != fileHash || (fileHash == nil && (existing.fileSize != fileSize || existing.fileModifiedAt != fileModifiedAt)) {
                try invalidateCurrentText(db, documentId: existing.id)
                try setExtractionState(db, ExtractionState(documentId: existing.id, status: .pending))
            }
            try db.run(
                """
                UPDATE documents SET
                    file_size = ?, file_modified_iso = ?, file_hash = ?, updated_at_iso = ?
                WHERE id = ?
                """,
                [fileSize, modified, fileHash, now, existing.id]
            )
            try refreshDocumentsFTS(db, rowid: existing.rowid, fileName: fileName, pathForIndex: path)
            guard let updated = try document(db, id: existing.id) else {
                throw DocumentIndexError.notFound("документ \(existing.id)")
            }
            return updated
        }

        let newId = UUID().uuidString
        try db.run(
            """
            INSERT INTO documents(
                id, location_kind, absolute_path, file_name, file_name_lower, file_extension,
                file_size, file_modified_iso, file_hash, created_by_app, created_at_iso, updated_at_iso
            ) VALUES (?, 'external', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                newId, path, fileName, fileName.lowercased(), fileExtension,
                fileSize, modified, fileHash, createdByApp, now, now,
            ]
        )
        guard let created = try document(db, id: newId) else {
            throw DocumentIndexError.notFound("документ \(newId)")
        }
        try refreshDocumentsFTS(db, rowid: created.rowid, fileName: fileName, pathForIndex: path)
        return created
    }

    static func moveDocument(
        _ db: SQLite.Connection,
        id: String,
        toWorkspaceRootId: String,
        relativePath: String
    ) throws -> IndexedDocument {
        guard try document(db, id: id) != nil else {
            throw DocumentIndexError.notFound("документ \(id)")
        }
        let parsed = try parseWorkspaceFilePath(relativePath)
        if let conflict = try document(db, workspaceRootId: toWorkspaceRootId, relativePath: parsed.relativePath),
           conflict.id != id {
            throw DocumentIndexError.invalidArgument(
                "документ уже есть по пути \(parsed.relativePath)"
            )
        }
        let folder = try ensureFolder(db, workspaceRootId: toWorkspaceRootId, relativePath: parsed.folderPath)
        let caseId = try caseContaining(db, folderId: folder.id)?.id
        let now = iso(Date())
        try db.run(
            """
            UPDATE documents SET
                location_kind = 'workspace',
                workspace_root_id = ?,
                folder_id = ?,
                case_id = ?,
                relative_path = ?,
                absolute_path = NULL,
                file_name = ?,
                file_name_lower = ?,
                file_extension = ?,
                updated_at_iso = ?
            WHERE id = ?
            """,
            [
                toWorkspaceRootId, folder.id, caseId, parsed.relativePath,
                parsed.fileName, parsed.fileName.lowercased(), parsed.fileExtension, now, id,
            ]
        )
        guard let updated = try document(db, id: id) else {
            throw DocumentIndexError.notFound("документ \(id)")
        }
        try refreshDocumentsFTS(
            db, rowid: updated.rowid, fileName: parsed.fileName, pathForIndex: parsed.relativePath
        )
        return updated
    }

    static func deleteDocument(_ db: SQLite.Connection, id: String) throws {
        guard let existing = try document(db, id: id) else {
            throw DocumentIndexError.notFound("документ \(id)")
        }
        try db.run("DELETE FROM documents_fts WHERE rowid = ?", existing.rowid)
        try db.run("DELETE FROM documents WHERE id = ?", id)
    }

    static func searchDocumentsFTS(
        _ db: SQLite.Connection,
        match: String,
        scope: SearchScope,
        limit: Int, includeCaseLinks: Bool
    ) throws -> [IndexedDocument] {
        let fragment = ScopeSQL(scope: scope, includeCaseLinks: includeCaseLinks)
        let sql = fragment.withClause + """
            SELECT \(documentColumns)
            FROM documents_fts
            JOIN documents d ON d.rowid = documents_fts.rowid
            WHERE documents_fts MATCH ? AND \(fragment.predicate)
            ORDER BY bm25(documents_fts)
            LIMIT \(limit)
            """
        let bindings = boxed(fragment.cteBindings) + [match] + boxed(fragment.predicateBindings)
        return try allDocuments(db, sql, bindings)
    }

    static func searchDocumentsLike(
        _ db: SQLite.Connection,
        query: String,
        scope: SearchScope,
        limit: Int, includeCaseLinks: Bool
    ) throws -> [IndexedDocument] {
        let fragment = ScopeSQL(scope: scope, includeCaseLinks: includeCaseLinks)
        let sql = fragment.withClause + """
            SELECT \(documentColumns)
            FROM documents d
            WHERE d.file_name_lower LIKE ? ESCAPE '\\' AND \(fragment.predicate)
            ORDER BY d.file_name_lower
            LIMIT \(limit)
            """
        let pattern = "%" + DocumentSearchQuery.escapeForLike(query.lowercased()) + "%"
        let bindings = boxed(fragment.cteBindings) + [pattern] + boxed(fragment.predicateBindings)
        return try allDocuments(db, sql, bindings)
    }
}
