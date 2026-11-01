import Foundation
import SQLite

struct HydratedHit: Sendable {
    let chunkRowid: Int64
    let hit: ChunkSearchResult
}

extension DocumentIndexStore {

    /// Гидратация семантических совпадений: `score` и порядок — как у `matches`,
    /// `source = .semantic`. Копии одного `text_hash` идут подряд на позиции чанка.
    /// Документы вне области отбрасываются SQL-предикатом.
    public func hydrateChunks(
        matches: [VectorMatch],
        scope: SearchScope,
        variantFilter: DocumentTextVariantFilter = .original
    ) throws -> [ChunkSearchResult] {
        guard !matches.isEmpty else { return [] }
        let db = try db()
        let roots = try workspaceRootPaths(db)
        var texts: [String: String] = [:]
        let rowids = matches.map(\.chunkRowid)
        guard let statement = DocumentIndexQuery.chunkRowidsStatement(
            rowids: rowids,
            variantFilter: variantFilter,
            scope: scope, includeCaseLinks: try currentCapabilities().supportsExplicitCaseDocuments
        ) else { return [] }

        let rows = try readHits(db, statement: statement, roots: roots, texts: &texts)
        var byRowid: [Int64: [ChunkSearchResult]] = [:]
        for row in rows {
            byRowid[row.chunkRowid, default: []].append(row.hit)
        }

        var results: [ChunkSearchResult] = []
        results.reserveCapacity(matches.count)
        for match in matches {
            guard let copies = byRowid[match.chunkRowid] else { continue }
            for copy in copies {
                results.append(copy.with(score: match.score, source: .semantic))
            }
        }
        return results
    }

    /// Соседи чанка, если документ неизвестен: берётся первый текущий вариант текста.
    /// Нужно ИИ-инструменту `read_document_chunk`, который знает только `chunkId`.
    public func chunkContext(
        chunkId: String,
        surroundingChunks: Int = 1
    ) throws -> [ChunkSearchResult] {
        guard let documentId = try documentId(forChunkId: chunkId) else { return [] }
        return try chunkContext(
            chunkId: chunkId,
            documentId: documentId,
            surroundingChunks: surroundingChunks
        )
    }

    /// Соседи по `chunk_index` того же `text_hash`, привязанные к документу.
    /// Края текста обрезаются; отсутствующий чанк или документ — пустой массив.
    public func chunkContext(
        chunkId: String,
        documentId: String,
        surroundingChunks: Int = 1
    ) throws -> [ChunkSearchResult] {
        guard !chunkId.isEmpty, !documentId.isEmpty else { return [] }
        guard let anchor = try chunk(id: chunkId) else { return [] }
        let db = try db()
        let radius = max(surroundingChunks, 0)
        let lower = Int64(max(anchor.chunkIndex - radius, 0))
        let upper = Int64(anchor.chunkIndex + radius)

        var neighborRowids: [Int64] = []
        for row in try db.prepare(
            """
            SELECT rowid FROM chunks
            WHERE text_hash = ? AND chunk_index BETWEEN ? AND ?
            ORDER BY chunk_index
            """,
            anchor.textHash, lower, upper
        ) {
            if let rowid = RowReader(row).int64(0) {
                neighborRowids.append(rowid)
            }
        }
        guard let statement = DocumentIndexQuery.chunkRowidsStatement(
            rowids: neighborRowids,
            variantFilter: .all,
            scope: .documents(ids: [documentId])
        ) else { return [] }

        let roots = try workspaceRootPaths(db)
        var texts: [String: String] = [:]
        let rows = try readHits(db, statement: statement, roots: roots, texts: &texts)
        var byRowid: [Int64: [ChunkSearchResult]] = [:]
        for row in rows {
            byRowid[row.chunkRowid, default: []].append(row.hit)
        }
        return neighborRowids.flatMap { rowid in
            (byRowid[rowid] ?? []).map { $0.with(score: 0, source: .lexical) }
        }
    }

    private func documentId(forChunkId chunkId: String) throws -> String? {
        for row in try db().prepare(
            """
            SELECT tv.document_id
            FROM chunks c
            JOIN text_variants tv ON tv.text_hash = c.text_hash AND tv.is_current = 1
            WHERE c.id = ?
            ORDER BY tv.variant_type
            LIMIT 1
            """,
            chunkId
        ) {
            return RowReader(row).string(0)
        }
        return nil
    }

    // MARK: Общая гидратация строк keyword/semantic

    internal func workspaceRootPaths(_ db: SQLite.Connection) throws -> [String: String] {
        localWorkspacePaths
    }

    internal func readHits(
        _ db: SQLite.Connection,
        statement: DocumentIndexQuery.Statement,
        roots: [String: String],
        texts: inout [String: String]
    ) throws -> [HydratedHit] {
        var hits: [HydratedHit] = []
        for row in try db.prepare(statement.sql, statement.sqliteBindings) {
            if let hit = try hit(from: RowReader(row), db: db, roots: roots, texts: &texts) {
                hits.append(hit)
            }
        }
        return hits
    }

    internal func hit(
        from reader: RowReader,
        db: SQLite.Connection,
        roots: [String: String],
        texts: inout [String: String]
    ) throws -> HydratedHit? {
        guard let chunkRowid = reader.int64(DocumentIndexQuery.Column.chunkRowid),
              let chunkId = reader.string(DocumentIndexQuery.Column.chunkId),
              let textHash = reader.string(DocumentIndexQuery.Column.textHash),
              let utf16Start = reader.int(DocumentIndexQuery.Column.utf16Start),
              let utf16End = reader.int(DocumentIndexQuery.Column.utf16End),
              let documentId = reader.string(DocumentIndexQuery.Column.documentId),
              let locationKind = reader.string(DocumentIndexQuery.Column.locationKind),
              let fileName = reader.string(DocumentIndexQuery.Column.fileName),
              let variantType = reader.string(DocumentIndexQuery.Column.variantType)
        else { return nil }

        let content = try chunkSlice(
            db,
            textHash: textHash,
            utf16Start: utf16Start,
            utf16End: utf16End,
            cache: &texts
        )
        let (fileURL, relativePath) = Self.fileLocation(
            locationKind: locationKind,
            workspaceRootId: reader.string(DocumentIndexQuery.Column.workspaceRootId),
            relativePath: reader.string(DocumentIndexQuery.Column.relativePath),
            absolutePath: reader.string(DocumentIndexQuery.Column.absolutePath),
            roots: roots
        )
        let rank = reader.double(DocumentIndexQuery.Column.rank)

        return HydratedHit(
            chunkRowid: chunkRowid,
            hit: ChunkSearchResult(
                id: "\(chunkId)|\(documentId)",
                chunkId: chunkId,
                documentId: documentId,
                fileURL: fileURL,
                fileName: fileName,
                relativePath: relativePath,
                variantType: variantType,
                documentTextHash: textHash,
                content: content,
                utf16Start: utf16Start,
                utf16End: utf16End,
                pageNumber: reader.int(DocumentIndexQuery.Column.pageNumber),
                score: rank.map { Float(-$0) } ?? 0,
                source: .lexical
            )
        )
    }

    internal func chunkSlice(
        _ db: SQLite.Connection,
        textHash: String,
        utf16Start: Int,
        utf16End: Int,
        cache: inout [String: String]
    ) throws -> String {
        if let cached = cache[textHash] {
            return Self.slice(cached, utf16Start: utf16Start, utf16End: utf16End)
        }
        var content = ""
        for row in try db.prepare("SELECT content FROM texts WHERE text_hash = ?", textHash) {
            content = RowReader(row).string(0) ?? ""
            break
        }
        cache[textHash] = content
        return Self.slice(content, utf16Start: utf16Start, utf16End: utf16End)
    }

    /// Путь файла из каталога, без обращения к диску.
    internal static func fileLocation(
        locationKind: String,
        workspaceRootId: String?,
        relativePath: String?,
        absolutePath: String?,
        roots: [String: String]
    ) -> (url: URL, relativePath: String) {
        if locationKind == DocumentLocationKind.external.rawValue {
            let path = absolutePath ?? ""
            return (URL(fileURLWithPath: path), path)
        }
        let relative = relativePath ?? ""
        if let rootId = workspaceRootId, let root = roots[rootId] {
            let url = URL(fileURLWithPath: root, isDirectory: true)
                .appending(path: relative, directoryHint: .notDirectory)
            return (url, relative)
        }
        return (DocumentIndexPath.unavailableURL(workspaceRootId: workspaceRootId ?? "unknown", relativePath: relative), relative)
    }
}

extension ChunkSearchResult {
    func with(score: Float, source: ChunkSearchSource) -> ChunkSearchResult {
        ChunkSearchResult(
            id: id,
            chunkId: chunkId,
            documentId: documentId,
            fileURL: fileURL,
            fileName: fileName,
            relativePath: relativePath,
            variantType: variantType,
            documentTextHash: documentTextHash,
            content: content,
            utf16Start: utf16Start,
            utf16End: utf16End,
            pageNumber: pageNumber,
            score: score,
            source: source
        )
    }
}
