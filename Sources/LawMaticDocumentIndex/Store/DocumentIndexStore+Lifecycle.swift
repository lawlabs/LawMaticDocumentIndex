import Foundation
import SQLite

extension DocumentIndexStore {
    /// Commits text, provenance, page ranges, extraction state and embedding jobs together.
    /// The caller supplies the hash captured before extraction and verifies the file again afterwards.
    public func storeExtraction(
        documentId: String,
        content: String,
        state: ExtractionState,
        pages: [TextPageRange] = [],
        sourceFileHash: String?
    ) throws {
        guard state.documentId == documentId else {
            throw DocumentIndexError.invalidArgument("extraction/document ID mismatch")
        }
        try write { db in
            guard let document = try Self.document(db, id: documentId) else {
                throw DocumentIndexError.notFound(documentId)
            }
            if let currentHash = document.fileHash, let sourceFileHash, currentHash != sourceFileHash {
                throw DocumentIndexError.invalidArgument("файл изменился во время извлечения")
            }
            if let total = state.pagesTotal, let processed = state.pagesProcessed,
               state.status == .complete && processed < total {
                throw DocumentIndexError.invalidArgument("неполное извлечение не может иметь статус complete")
            }
            let hasText = !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if state.status == .complete && !hasText {
                throw DocumentIndexError.invalidArgument("complete без текста")
            }
            if hasText && (state.status == .complete || state.status == .partial) {
                let attached = try attachText(documentId: documentId, content: content, pages: pages)
                try db.run("DELETE FROM variant_pages WHERE variant_id = ?", attached.variant.id)
                let length = content.utf16.count
                for page in pages {
                    guard page.pageNumber > 0, page.utf16Start >= 0,
                          page.utf16Start <= page.utf16End, page.utf16End <= length else {
                        throw DocumentIndexError.invalidArgument("некорректные границы страницы")
                    }
                    try db.run("INSERT INTO variant_pages VALUES (?, ?, ?, ?)",
                        attached.variant.id, page.pageNumber, page.utf16Start, page.utf16End)
                }
                if let modelId = try metadata(DocumentIndexSchema.MetadataKey.defaultEmbeddingModelId) {
                    _ = try enqueueEmbedJobs(in: .documents(ids: [documentId]), modelId: modelId)
                }
                _ = try completeStaleEmbedJobs()
            } else {
                try Self.invalidateCurrentText(db, documentId: documentId)
                _ = try completeStaleEmbedJobs()
            }
            try Self.setExtractionState(db, state)
            try db.run("""
                INSERT INTO extraction_fingerprints(document_id, source_file_hash) VALUES (?, ?)
                ON CONFLICT(document_id) DO UPDATE SET source_file_hash = excluded.source_file_hash
                """, documentId, sourceFileHash)
        }
    }

    static func invalidateCurrentText(_ db: SQLite.Connection, documentId: String) throws {
        let hashes = try currentTextHashes(db, documentId: documentId)
        try db.run("UPDATE text_variants SET is_current = 0 WHERE document_id = ?", documentId)
        for hash in hashes { try rebuildChunkFTS(db, textHash: hash) }
    }

    /// Removal is explicit; a temporarily unavailable directory must never call this method.
    @discardableResult
    public func removeDocuments(in scope: SearchScope, mutationGuard: DocumentIndexMutationGuard? = nil) throws -> Int {
        try write { db in
            try validateMutation(mutationGuard, db: db)
            let documents = try self.documents(in: scope)
            for document in documents {
                let location = document.absolutePath ?? document.relativePath ?? ""
                try db.run("INSERT INTO index_removals VALUES (?, ?, ?) ON CONFLICT(root_id, path) DO UPDATE SET removed_at_iso = excluded.removed_at_iso",
                    document.workspaceRootId ?? "", location, Self.iso(Date()))
                let hashes = try Self.currentTextHashes(db, documentId: document.id)
                try Self.deleteDocument(db, id: document.id)
                try Self.rebuildChunkFTSIfLinked(db, textHashes: hashes)
            }
            _ = try collectOrphanTexts()
            return documents.count
        }
    }

    public func clearIndex(mutationGuard: DocumentIndexMutationGuard? = nil) throws {
        try write { db in
            try validateMutation(mutationGuard, db: db)
            _ = try removeDocuments(in: .everything)
            try db.run("DELETE FROM cases")
            try db.run("DELETE FROM index_jobs")
            try setMetadata("index_last_clear_at", Self.iso(Date()))
        }
    }

    /// Согласованный переносимый снимок: `VACUUM INTO` во временный файл на том же
    /// томе, проверка контракта, затем атомарная публикация. Живые WAL/SHM не копируются.
    public func exportSnapshot(to destination: URL) throws {
        try requireWritable()
        let dest = destination.standardizedFileURL
        guard dest != databaseURL.standardizedFileURL else {
            throw DocumentIndexError.invalidArgument("нельзя экспортировать снимок поверх открытой базы")
        }
        let directory = dest.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let temp = directory.appendingPathComponent(
            ".lawmatic-export-\(UUID().uuidString).sqlite"
        )
        var published = false
        defer {
            if !published {
                try? FileManager.default.removeItem(at: temp)
            }
        }
        try db().run("VACUUM INTO ?", temp.path)
        let info = try DocumentIndexSnapshot.inspect(
            temp,
            options: .publishedExport
        )
        try DocumentIndexSnapshot.publishAtomically(from: temp, to: dest)
        published = true

        let manifest = DocumentIndexManifest(
            writerAppId: writerAppId,
            writerAppVersion: "snapshot",
            lastWriteISO: Self.iso(Date()),
            defaultEmbeddingModelId: try metadata(DocumentIndexSchema.MetadataKey.defaultEmbeddingModelId),
            indexGeneration: info.generation,
            snapshotId: UUID().uuidString
        )
        try manifest.save(to: DocumentIndexSnapshot.manifestURL(forDatabase: dest))
    }
}

public enum IndexedFileLocation: Sendable {
    case workspace(rootId: String, relativePath: String)
    case external(absolutePath: String)
}

extension DocumentIndexStore {
    /// Whole-file ingest is atomic, including the catalogue row and invalidation of older variants.
    @discardableResult
    public func ingestFile(location: IndexedFileLocation, fileSize: Int64, modifiedAt: Date,
                           fileHash: String?, content: String, extraction: ExtractionState,
                           pages: [TextPageRange] = [], extractionStartedAt: Date? = nil) throws -> IndexedDocument {
        try write { db in
            if let extractionStartedAt {
                let rootID: String
                let path: String
                switch location {
                case let .workspace(rootId, relativePath): rootID = rootId; path = try SearchScope.validatedRelativePath(relativePath)
                case let .external(absolutePath): rootID = ""; path = Self.normalizeLocalPath(absolutePath)
                }
                let removedAt = try db.scalar("SELECT removed_at_iso FROM index_removals WHERE root_id = ? AND path = ?", rootID, path) as? String
                let clearedAt = try metadata("index_last_clear_at")
                let started = Self.iso(extractionStartedAt)
                if [removedAt, clearedAt].compactMap({ $0 }).contains(where: { $0 >= started }) {
                    throw DocumentIndexError.invalidArgument("извлечение началось до удаления из индекса; результат отменён")
                }
            }
            let document: IndexedDocument
            switch location {
            case let .workspace(rootId, relativePath):
                document = try upsertWorkspaceDocument(workspaceRootId: rootId, relativePath: relativePath,
                    fileSize: fileSize, fileModifiedAt: modifiedAt, fileHash: fileHash)
            case let .external(absolutePath):
                document = try upsertExternalDocument(absolutePath: absolutePath,
                    fileSize: fileSize, fileModifiedAt: modifiedAt, fileHash: fileHash)
            }
            let previous = try extractionState(documentId: document.id)
            let attempts = (previous?.attempts ?? 0) + 1
            let retryAfter = extraction.nextRetryAfter ?? ExtractionRetry.nextRetryAfter(
                status: extraction.status,
                errorCode: extraction.errorCode,
                attempts: attempts
            )
            let state = ExtractionState(documentId: document.id, status: extraction.status,
                extractorId: extraction.extractorId, extractorVersion: extraction.extractorVersion,
                methodLabel: extraction.methodLabel, pagesTotal: extraction.pagesTotal,
                pagesProcessed: extraction.pagesProcessed, errorCode: extraction.errorCode,
                errorMessage: extraction.errorMessage, attempts: attempts,
                nextRetryAfter: retryAfter, finishedAt: extraction.finishedAt)
            try storeExtraction(documentId: document.id, content: content, state: state,
                pages: pages, sourceFileHash: fileHash)
            return document
        }
    }

    public func moveToExternal(documentId: String, absolutePath: String, mutationGuard: DocumentIndexMutationGuard? = nil) throws {
        try write { db in
            try validateMutation(mutationGuard, db: db)
            guard let document = try Self.document(db, id: documentId) else { return }
            let path = Self.normalizeLocalPath(absolutePath)
            guard path.hasPrefix("/"), path != "/" else { throw DocumentIndexError.invalidArgument("invalid destination") }
            let name = URL(fileURLWithPath: path).lastPathComponent
            try db.run("""
                UPDATE documents SET location_kind = 'external', workspace_root_id = NULL,
                    folder_id = NULL, case_id = NULL, relative_path = NULL, absolute_path = ?,
                    file_name = ?, file_name_lower = ?, file_extension = ?, updated_at_iso = ? WHERE id = ?
                """, path, name, name.lowercased(), (name as NSString).pathExtension.lowercased(), Self.iso(Date()), documentId)
            try Self.refreshDocumentsFTS(db, rowid: document.rowid, fileName: name, pathForIndex: path)
            try Self.rebuildChunkFTSForDocument(db, documentId: documentId)
        }
    }

    /// Moves cases with their folder tree before assigning documents to the new nearest case.
    public func moveFolder(workspaceRootId: String, relativePath: String,
                           toRootId: String, destinationPath: String, mutationGuard: DocumentIndexMutationGuard? = nil) throws {
        let oldPath = try SearchScope.validatedRelativePath(relativePath)
        let newPath = try SearchScope.validatedRelativePath(destinationPath)
        guard !oldPath.isEmpty else { throw DocumentIndexError.invalidArgument("use a local binding to move a workspace root") }
        try write { db in
            try validateMutation(mutationGuard, db: db)
            let records = try documents(in: .folderPath(workspaceRootId: workspaceRootId, relativePath: oldPath, recursive: true))
            for item in try cases(workspaceRootId: workspaceRootId) {
                guard let folder = try folder(id: item.rootFolderId),
                      folder.relativePath == oldPath || folder.relativePath.hasPrefix(oldPath + "/") else { continue }
                let suffix = String(folder.relativePath.dropFirst(oldPath.count))
                let target = try ensureFolder(workspaceRootId: toRootId, relativePath: newPath + suffix)
                try db.run("UPDATE cases SET workspace_root_id = ?, root_folder_id = ?, updated_at_iso = ? WHERE id = ?",
                    toRootId, target.id, Self.iso(Date()), item.id)
            }
            for record in records {
                let suffix = String((record.relativePath ?? "").dropFirst(oldPath.count))
                _ = try moveDocument(id: record.id, toWorkspaceRootId: toRootId, relativePath: newPath + suffix)
            }
            try reassignCases(workspaceRootId: workspaceRootId)
            if toRootId != workspaceRootId { try reassignCases(workspaceRootId: toRootId) }
        }
    }
}
