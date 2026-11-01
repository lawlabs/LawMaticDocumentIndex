import Foundation

extension DocumentIndexStore {
    /// Extraction may create a missing case, but must never rename an existing one.
    @discardableResult
    public func ensureCase(workspaceRootId: String, rootFolderPath: String, title: String) throws -> CaseRecord {
        try write { _ in
            if let existing = try caseAt(workspaceRootId: workspaceRootId, rootFolderPath: rootFolderPath) {
                return existing
            }
            return try upsertCase(workspaceRootId: workspaceRootId, rootFolderPath: rootFolderPath, title: title)
        }
    }

    @discardableResult
    public func saveCaseCard(workspaceRootId: String, rootFolderPath: String, title: String,
                             card: CaseCardRecord) throws -> CaseRecord {
        try write { _ in
            let record = try upsertCase(workspaceRootId: workspaceRootId, rootFolderPath: rootFolderPath, title: title)
            var resolved = card
            resolved.caseId = record.id
            _ = try upsertCaseCard(resolved)
            return record
        }
    }

    /// Card, lists, tags and relations are published together. Document extraction is separate.
    @discardableResult
    public func saveCaseSnapshot(workspaceRootId: String, rootFolderPath: String, title: String,
                                 card: CaseCardRecord, items: [CaseListItemRecord],
                                 tags: [CaseTagRecord], relations: [DocumentRelationRecord]) throws -> CaseRecord {
        try write { _ in
            let record = try saveCaseCard(workspaceRootId: workspaceRootId, rootFolderPath: rootFolderPath,
                                          title: title, card: card)
            for kind in CaseListKind.allCases {
                let incoming = items.filter { $0.kind == kind }
                let ids = Set(incoming.map(\.id))
                for existing in try caseListItems(caseId: record.id, kind: kind) where !ids.contains(existing.id) {
                    try deleteCaseListItem(kind: kind, id: existing.id)
                }
                for var item in incoming {
                    item.caseId = record.id
                    _ = try upsertCaseListItem(item)
                }
            }
            try replaceCaseTags(caseId: record.id, tags: tags.map { item in
                var copy = item; copy.caseId = record.id; return copy
            })
            try replaceDocumentRelations(caseId: record.id, relations: relations.map { item in
                var copy = item; copy.caseId = record.id; return copy
            })
            return record
        }
    }

    /// Do not use wholeCase here: explicitly attached documents are shared, and child cases are independent.
    @discardableResult
    public func clearCase(id: String, mutationGuard: DocumentIndexMutationGuard? = nil) throws -> Int {
        try write { db in
            try validateMutation(mutationGuard, db: db)
            guard let record = try caseRecord(id: id) else { return 0 }
            let path = try folder(id: record.rootFolderId)?.relativePath ?? ""
            try setMetadata(Self.caseClearKey(rootId: record.workspaceRootId, path: path), Self.iso(Date()))
            let ids = try db.prepare("""
                SELECT d.id FROM documents d WHERE d.case_id = ? AND NOT EXISTS (
                    SELECT 1 FROM case_document_links l WHERE l.document_id = d.id AND l.case_id != ?
                )
                """, id, id).compactMap { $0[0] as? String }
            let count = try removeDocuments(in: .documents(ids: ids))
            try deleteCase(id: id)
            return count
        }
    }

    static func caseClearKey(rootId: String, path: String) -> String {
        "case_last_clear:\(rootId):\(path)"
    }

    /// Additive AI edits never replace the card, unrelated lists, tags or relations.
    public func upsertCaseListItems(caseId: String, items: [CaseListItemRecord]) throws {
        try write { _ in
            guard try caseRecord(id: caseId) != nil else { throw DocumentIndexError.notFound(caseId) }
            for kind in CaseListKind.allCases {
                let existing = try caseListItems(caseId: caseId, kind: kind)
                var sorts = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0.sortIndex) })
                var nextSort = (existing.map(\.sortIndex).max() ?? -1) + 1
                for var item in items where item.kind == kind {
                    item.caseId = caseId
                    item.sortIndex = sorts[item.id] ?? nextSort
                    if sorts[item.id] == nil { sorts[item.id] = nextSort; nextSort += 1 }
                    _ = try upsertCaseListItem(item)
                }
            }
        }
    }

    /// One transaction for the text variant, run, mappings, occurrences and review metadata.
    @discardableResult
    public func saveAnonymization(content: String, run: AnonymizationRunRecord,
                                  entities: [AnonymizationEntityRecord], occurrences: [AnonymizationOccurrenceRecord],
                                  expectedSourceTextHash: String?) throws -> AnonymizationRunRecord {
        try write { _ in
            let source = try textVariant(documentId: run.documentId, type: .original)
            guard source?.textHash == expectedSourceTextHash else {
                throw DocumentIndexError.invalidArgument("Исходный текст изменился. Подготовьте обезличенную копию заново.")
            }
            let attached = try attachText(documentId: run.documentId, type: .anonymized,
                                           content: content, sourceVariantId: source?.id)
            let latest = try latestAnonymizationRun(documentId: run.documentId)?.0
            var resolved = run
            resolved.id = latest?.id ?? ""
            resolved.createdAt = latest?.createdAt ?? run.createdAt
            resolved.sourceTextVariantId = source?.id
            resolved.resultTextVariantId = attached.variant.id
            let positions = occurrences.map { item in
                var copy = item
                copy.sourceTextVariantId = source?.id
                copy.resultTextVariantId = attached.variant.id
                return copy
            }
            return try upsertAnonymizationRun(resolved, entities: entities, occurrences: positions).0
        }
    }
}

/// Device-local bindings accompanying an atomic catalogue/extraction write.
public struct DocumentIndexCaseIngestContext: Sendable {
    public let rootId: String
    public let rootName: String
    public let localPath: String
    public let casePath: String
    public let title: String
    public init(rootId: String, rootName: String, localPath: String, casePath: String, title: String) {
        self.rootId = rootId; self.rootName = rootName; self.localPath = localPath
        self.casePath = casePath; self.title = title
    }
}

extension DocumentIndexStore {
    /// No intermediate case, promotion or attachment survives a rejected extraction.
    public func ingestCaseDocument(location: IndexedFileLocation, physicalRoot: DocumentIndexCaseIngestContext?,
                                   caseContext: DocumentIndexCaseIngestContext?, attachToCase: Bool,
                                   absolutePath: String, fileSize: Int64, modifiedAt: Date, fileHash: String?,
                                   content: String?, extraction: ExtractionState?, pages: [TextPageRange] = [],
                                   startedAt: Date, mutationGuard: DocumentIndexMutationGuard) throws -> IndexedDocument {
        let previousBindings = localWorkspacePaths
        do {
            return try write { db in
                try validateMutation(mutationGuard, db: db)
                let started = Self.iso(startedAt)
                var clears = [try metadata("index_last_clear_at")]
                if let context = caseContext {
                    let path = try SearchScope.validatedRelativePath(context.casePath)
                    clears.append(try metadata(Self.caseClearKey(rootId: context.rootId, path: path)))
                }
                let rootId: String
                let path: String
                switch location {
                case let .workspace(id, relative): rootId = id; path = try SearchScope.validatedRelativePath(relative)
                case let .external(absolute): rootId = ""; path = Self.normalizeLocalPath(absolute)
                }
                clears.append(try db.scalar("SELECT removed_at_iso FROM index_removals WHERE root_id = ? AND path = ?", rootId, path) as? String)
                guard !clears.compactMap({ $0 }).contains(where: { $0 >= started }) else {
                    throw DocumentIndexError.invalidArgument("Извлечение началось до очистки дела или удаления документа; результат отменён.")
                }
                for context in [caseContext, physicalRoot].compactMap({ $0 }) {
                    _ = try registerWorkspaceRoot(id: context.rootId, name: context.rootName, localPath: context.localPath)
                }
                let selected = try caseContext.map {
                    try ensureCase(workspaceRootId: $0.rootId, rootFolderPath: $0.casePath, title: $0.title)
                }
                if case let .workspace(id, relative) = location,
                   try document(workspaceRootId: id, relativePath: relative) == nil,
                   let external = try document(absolutePath: absolutePath) {
                    _ = try moveDocument(id: external.id, toWorkspaceRootId: id, relativePath: relative)
                }
                let indexed: IndexedDocument
                if let extraction {
                    indexed = try ingestFile(location: location, fileSize: fileSize, modifiedAt: modifiedAt,
                        fileHash: fileHash, content: content ?? "", extraction: extraction, pages: pages, extractionStartedAt: startedAt)
                } else {
                    switch location {
                    case let .workspace(id, relative):
                        indexed = try upsertWorkspaceDocument(workspaceRootId: id, relativePath: relative,
                            fileSize: fileSize, fileModifiedAt: modifiedAt, fileHash: fileHash)
                    case let .external(path):
                        indexed = try upsertExternalDocument(absolutePath: path, fileSize: fileSize,
                            fileModifiedAt: modifiedAt, fileHash: fileHash)
                    }
                }
                if attachToCase, let selected { _ = try attachDocument(documentId: indexed.id, toCase: selected.id) }
                try validateMutation(mutationGuard, db: db)
                return indexed
            }
        } catch {
            localWorkspacePaths = previousBindings
            throw error
        }
    }
}
