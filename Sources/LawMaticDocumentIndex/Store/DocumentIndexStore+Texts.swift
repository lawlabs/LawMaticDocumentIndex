import CryptoKit
import Foundation
import SQLite

public struct StoredText: Equatable, Sendable {
    public let textHash: String
    public let utf16Length: Int
    public let chunkCount: Int
    public let isNew: Bool

    public init(textHash: String, utf16Length: Int, chunkCount: Int, isNew: Bool) {
        self.textHash = textHash
        self.utf16Length = utf16Length
        self.chunkCount = chunkCount
        self.isNew = isNew
    }
}

extension DocumentIndexStore {

    /// SHA-256 (hex, нижний регистр) от UTF-8 содержимого. `nonisolated` — чистая функция,
    /// её вызывают и снаружи actor, и из тестов без `await`.
    nonisolated public static func textHash(of content: String) -> String {
        SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Контентно-адресуемая запись: повтор с тем же хешем ничего не пишет.
    /// `fileNames` — сырые имена документов, если они уже известны (текст ещё
    /// можно сохранить до вариантов). Пустой список — FTS только по содержимому.
    @discardableResult
    public func storeText(
        _ content: String,
        pages: [TextPageRange] = [],
        languageCode: String? = "ru",
        fileNames: [String] = []
    ) throws -> StoredText {
        let hash = Self.textHash(of: content)
        let utf16Length = (content as NSString).length
        if let existing = try storedTextSummary(try db(), hash: hash, utf16Length: utf16Length) {
            return existing
        }

        return try write { db in
            if let existing = try storedTextSummary(db, hash: hash, utf16Length: utf16Length) {
                return existing
            }

            let now = Self.iso(Date())
            try db.run(
                """
                INSERT INTO texts(text_hash, content, utf16_length, language_code, created_at_iso)
                VALUES (?, ?, ?, ?, ?)
                """,
                hash, content, Int64(utf16Length), languageCode, now
            )

            for page in pages {
                try db.run(
                    """
                    INSERT INTO text_pages(text_hash, page_number, utf16_start, utf16_end)
                    VALUES (?, ?, ?, ?)
                    """,
                    hash, Int64(page.pageNumber), Int64(page.utf16Start), Int64(page.utf16End)
                )
            }

            let fileNameNorm = Self.joinedFileNamesNorm(fileNames)
            var chunkCount = 0
            for draft in SearchChunker.chunks(from: content) {
                let pageNumber = Self.pageNumber(containing: draft.utf16Start, in: pages)
                try db.run(
                    """
                    INSERT INTO chunks(id, text_hash, chunk_index, utf16_start, utf16_end, page_number, section_path)
                    VALUES (?, ?, ?, ?, ?, ?, NULL)
                    """,
                    ChunkRecord.makeId(textHash: hash, chunkIndex: draft.chunkIndex),
                    hash,
                    Int64(draft.chunkIndex),
                    Int64(draft.utf16Start),
                    Int64(draft.utf16End),
                    pageNumber.map { Int64($0) }
                )
                try db.run(
                    "INSERT INTO chunk_fts(rowid, file_name_norm, content_norm) VALUES (?, ?, ?)",
                    db.lastInsertRowid,
                    fileNameNorm,
                    RussianTextNormalizer.normalizeForIndex(draft.content)
                )
                chunkCount += 1
            }

            return StoredText(textHash: hash, utf16Length: utf16Length, chunkCount: chunkCount, isNew: true)
        }
    }

    /// Одна транзакция: текст + текущий вариант. Для нового текста FTS сразу
    /// пишется с именем документа, без второй пересборки.
    @discardableResult
    public func attachText(
        documentId: String,
        type: TextVariantType = .original,
        content: String,
        pages: [TextPageRange] = [],
        languageCode: String? = "ru",
        sourceVariantId: String? = nil
    ) throws -> (text: StoredText, variant: TextVariantRecord) {
        try write { db in
            guard let document = try Self.document(db, id: documentId) else {
                throw DocumentIndexError.notFound(documentId)
            }
            let stored = try storeText(
                content,
                pages: pages,
                languageCode: languageCode,
                fileNames: [document.fileName]
            )
            // Новый текст уже проиндексирован с единственным именем; копия —
            // обычное сравнение наборов в setTextVariant.
            let variant = try setTextVariant(
                documentId: documentId,
                type: type,
                textHash: stored.textHash,
                sourceVariantId: sourceVariantId,
                skipFTSRebuild: stored.isNew
            )
            return (stored, variant)
        }
    }

    @discardableResult
    public func setTextVariant(
        documentId: String,
        type: TextVariantType,
        textHash: String,
        sourceVariantId: String? = nil
    ) throws -> TextVariantRecord {
        try setTextVariant(
            documentId: documentId,
            type: type,
            textHash: textHash,
            sourceVariantId: sourceVariantId,
            skipFTSRebuild: false
        )
    }

    @discardableResult
    func setTextVariant(
        documentId: String,
        type: TextVariantType,
        textHash: String,
        sourceVariantId: String?,
        skipFTSRebuild: Bool
    ) throws -> TextVariantRecord {
        try write { db in
            guard try db.scalar("SELECT 1 FROM documents WHERE id = ?", documentId) != nil else {
                throw DocumentIndexError.notFound(documentId)
            }
            guard try db.scalar("SELECT 1 FROM texts WHERE text_hash = ?", textHash) != nil else {
                throw DocumentIndexError.notFound(textHash)
            }

            let previousHash = try textVariantRecord(db, documentId: documentId, type: type)?.textHash
            let namesBefore = try Self.fileNamesNorm(db, textHash: textHash)
            if let previousHash, previousHash != textHash,
               let previous = try textVariantRecord(db, documentId: documentId, type: type) {
                var pages: [TextPageRange] = []
                for row in try db.prepare("SELECT page_number, utf16_start, utf16_end FROM variant_pages WHERE variant_id = ? ORDER BY page_number", previous.id) {
                    let reader = RowReader(row)
                    if let number = reader.int(0), let start = reader.int(1), let end = reader.int(2) {
                        pages.append(.init(pageNumber: number, utf16Start: start, utf16End: end))
                    }
                }
                let json = String(decoding: try JSONEncoder().encode(pages), as: UTF8.self)
                let fingerprint = try db.scalar("SELECT source_file_hash FROM extraction_fingerprints WHERE document_id = ?", documentId) as? String
                try db.run("INSERT INTO text_variant_history VALUES (?, ?, ?, ?, ?, ?, ?)",
                    UUID().uuidString, documentId, type.rawValue, previousHash, fingerprint, Self.iso(Date()), json)
                try db.run("DELETE FROM variant_pages WHERE variant_id = ?", previous.id)
                // An anonymized result belongs to its source text, even though the variant ID is stable.
                if type == .original {
                    try db.run("UPDATE text_variants SET is_current = 0 WHERE document_id = ? AND variant_type = 'anonymized'", documentId)
                }
            }

            let now = Self.iso(Date())
            try db.run(
                """
                INSERT INTO text_variants(
                    id, document_id, variant_type, text_hash, source_variant_id,
                    is_current, created_at_iso, updated_at_iso
                )
                VALUES (?, ?, ?, ?, ?, 1, ?, ?)
                ON CONFLICT(document_id, variant_type) DO UPDATE SET
                    text_hash = excluded.text_hash,
                    source_variant_id = excluded.source_variant_id,
                    is_current = 1,
                    updated_at_iso = excluded.updated_at_iso
                """,
                UUID().uuidString, documentId, type.rawValue, textHash, sourceVariantId, now, now
            )

            let namesAfter = try Self.fileNamesNorm(db, textHash: textHash)
            if !skipFTSRebuild, namesBefore != namesAfter {
                try rebuildChunkFTS(db, textHash: textHash)
            }
            if let previousHash, previousHash != textHash,
               try db.scalar("SELECT 1 FROM texts WHERE text_hash = ?", previousHash) != nil {
                try rebuildChunkFTS(db, textHash: previousHash)
            }

            guard let record = try textVariantRecord(db, documentId: documentId, type: type) else {
                throw DocumentIndexError.notFound(documentId)
            }
            return record
        }
    }

    /// Clear the current copy and every run/map atomically. FK cascades remove occurrences.
    public func clearAnonymization(documentId: String) throws {
        try write { db in
            let hash = try textVariantRecord(db, documentId: documentId, type: .anonymized)?.textHash
            try db.run("DELETE FROM anonymization_runs WHERE document_id = ?", documentId)
            try db.run("DELETE FROM text_variants WHERE document_id = ? AND variant_type = 'anonymized'", documentId)
            if let hash { try rebuildChunkFTS(db, textHash: hash) }
        }
    }

    public func removeTextVariant(documentId: String, type: TextVariantType) throws {
        try write { db in
            let previousHash = try textVariantRecord(db, documentId: documentId, type: type)?.textHash
            try db.run(
                "DELETE FROM text_variants WHERE document_id = ? AND variant_type = ?",
                documentId, type.rawValue
            )
            if let previousHash,
               try db.scalar("SELECT 1 FROM texts WHERE text_hash = ?", previousHash) != nil {
                try rebuildChunkFTS(db, textHash: previousHash)
            }
        }
    }

    public func textVariant(documentId: String, type: TextVariantType) throws -> TextVariantRecord? {
        try textVariants(documentId: documentId).first { $0.variantType == type && $0.isCurrent }
    }

    public func textVariants(documentId: String) throws -> [TextVariantRecord] {
        let db = try db()
        let sql = """
            SELECT id, document_id, variant_type, text_hash, source_variant_id,
                   is_current, created_at_iso, updated_at_iso
            FROM text_variants
            WHERE document_id = ?
            ORDER BY variant_type
            """
        return try db.prepare(sql, documentId).compactMap { Self.textVariantRecord(RowReader($0)) }
    }

    public func currentTextHash(documentId: String, type: TextVariantType) throws -> String? {
        let db = try db()
        for row in try db.prepare(
            """
            SELECT text_hash FROM text_variants
            WHERE document_id = ? AND variant_type = ? AND is_current = 1
            """,
            documentId, type.rawValue
        ) {
            return RowReader(row).string(0)
        }
        return nil
    }

    public func textRecord(hash: String) throws -> TextRecord? {
        let db = try db()
        for row in try db.prepare(
            "SELECT text_hash, utf16_length, language_code, created_at_iso FROM texts WHERE text_hash = ?",
            hash
        ) {
            let reader = RowReader(row)
            guard let textHash = reader.string(0),
                  let utf16Length = reader.int(1),
                  let createdAt = reader.date(3) else { return nil }
            return TextRecord(
                textHash: textHash,
                utf16Length: utf16Length,
                languageCode: reader.string(2),
                createdAt: createdAt
            )
        }
        return nil
    }

    public func textContent(hash: String) throws -> String? {
        let db = try db()
        for row in try db.prepare("SELECT content FROM texts WHERE text_hash = ?", hash) {
            return RowReader(row).string(0)
        }
        return nil
    }

    public func textPages(hash: String) throws -> [TextPageRange] {
        let db = try db()
        var pages: [TextPageRange] = []
        for row in try db.prepare(
            """
            SELECT page_number, utf16_start, utf16_end FROM text_pages
            WHERE text_hash = ? ORDER BY page_number
            """,
            hash
        ) {
            let reader = RowReader(row)
            guard let pageNumber = reader.int(0),
                  let utf16Start = reader.int(1),
                  let utf16End = reader.int(2) else { continue }
            pages.append(TextPageRange(pageNumber: pageNumber, utf16Start: utf16Start, utf16End: utf16End))
        }
        return pages
    }

    public func chunks(textHash: String) throws -> [ChunkRecord] {
        let db = try db()
        return try db.prepare(
            """
            SELECT rowid, id, text_hash, chunk_index, utf16_start, utf16_end, page_number, section_path
            FROM chunks WHERE text_hash = ? ORDER BY chunk_index
            """,
            textHash
        ).compactMap { Self.chunkRecord(RowReader($0)) }
    }

    public func chunk(id: String) throws -> ChunkRecord? {
        try chunkRecord(try db(), where: "id = ?", binding: id)
    }

    public func chunk(rowid: Int64) throws -> ChunkRecord? {
        try chunkRecord(try db(), where: "rowid = ?", binding: rowid)
    }

    public func chunkContent(_ chunk: ChunkRecord) throws -> String? {
        guard let content = try textContent(hash: chunk.textHash) else { return nil }
        return Self.slice(content, utf16Start: chunk.utf16Start, utf16End: chunk.utf16End)
    }

    /// Уникальные `chunks.rowid` текущих вариантов в области.
    /// Один текст на нескольких документах считается один раз: эмбеддинги висят на чанке.
    public func chunkCount(
        in scope: SearchScope,
        variantFilter: DocumentTextVariantFilter = .original
    ) throws -> Int {
        let db = try db()
        let scopeSQL = ScopeSQL(scope: scope, includeCaseLinks: try currentCapabilities().supportsExplicitCaseDocuments)
        var sql = scopeSQL.withClause + """
            SELECT COUNT(DISTINCT c.rowid)
            FROM chunks c
            JOIN text_variants tv ON tv.text_hash = c.text_hash AND tv.is_current = 1
            JOIN documents d ON d.id = tv.document_id
            WHERE \(scopeSQL.predicate)
            """
        var bindings: [Binding?] = scopeSQL.bindings.map { $0 }
        switch variantFilter {
        case .original:
            sql += " AND tv.variant_type = ?"
            bindings.append(TextVariantType.original.rawValue)
        case .anonymized:
            sql += " AND tv.variant_type = ?"
            bindings.append(TextVariantType.anonymized.rawValue)
        case .all:
            break
        }

        return Self.intCount(try db.scalar(sql, bindings))
    }

    public func documentText(documentId: String, type: TextVariantType = .original) throws -> String? {
        let db = try db()
        for row in try db.prepare(
            """
            SELECT t.content
            FROM text_variants tv
            JOIN texts t ON t.text_hash = tv.text_hash
            WHERE tv.document_id = ? AND tv.variant_type = ? AND tv.is_current = 1
            """,
            documentId, type.rawValue
        ) {
            return RowReader(row).string(0)
        }
        return nil
    }

    // MARK: Разбор строк

    private func storedTextSummary(
        _ db: SQLite.Connection,
        hash: String,
        utf16Length: Int
    ) throws -> StoredText? {
        guard try db.scalar("SELECT 1 FROM texts WHERE text_hash = ?", hash) != nil else {
            return nil
        }
        let count = Self.intCount(try db.scalar("SELECT COUNT(*) FROM chunks WHERE text_hash = ?", hash))
        return StoredText(textHash: hash, utf16Length: utf16Length, chunkCount: count, isNew: false)
    }

    private func textVariantRecord(
        _ db: SQLite.Connection,
        documentId: String,
        type: TextVariantType
    ) throws -> TextVariantRecord? {
        for row in try db.prepare(
            """
            SELECT id, document_id, variant_type, text_hash, source_variant_id,
                   is_current, created_at_iso, updated_at_iso
            FROM text_variants
            WHERE document_id = ? AND variant_type = ?
            """,
            documentId, type.rawValue
        ) {
            return Self.textVariantRecord(RowReader(row))
        }
        return nil
    }

    private func chunkRecord(
        _ db: SQLite.Connection,
        where predicate: String,
        binding: Binding
    ) throws -> ChunkRecord? {
        for row in try db.prepare(
            """
            SELECT rowid, id, text_hash, chunk_index, utf16_start, utf16_end, page_number, section_path
            FROM chunks WHERE \(predicate)
            """,
            binding
        ) {
            return Self.chunkRecord(RowReader(row))
        }
        return nil
    }

    private static func textVariantRecord(_ reader: RowReader) -> TextVariantRecord? {
        guard let id = reader.string(0),
              let documentId = reader.string(1),
              let typeRaw = reader.string(2),
              let type = TextVariantType(rawValue: typeRaw),
              let textHash = reader.string(3),
              let createdAt = reader.date(6),
              let updatedAt = reader.date(7) else { return nil }
        return TextVariantRecord(
            id: id,
            documentId: documentId,
            variantType: type,
            textHash: textHash,
            sourceVariantId: reader.string(4),
            isCurrent: reader.bool(5),
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private static func chunkRecord(_ reader: RowReader) -> ChunkRecord? {
        guard let rowid = reader.int64(0),
              let id = reader.string(1),
              let textHash = reader.string(2),
              let chunkIndex = reader.int(3),
              let utf16Start = reader.int(4),
              let utf16End = reader.int(5) else { return nil }
        return ChunkRecord(
            rowid: rowid,
            id: id,
            textHash: textHash,
            chunkIndex: chunkIndex,
            utf16Start: utf16Start,
            utf16End: utf16End,
            pageNumber: reader.int(6),
            sectionPath: reader.string(7)
        )
    }

    private static func pageNumber(containing utf16Start: Int, in pages: [TextPageRange]) -> Int? {
        pages.first { utf16Start >= $0.utf16Start && utf16Start < $0.utf16End }?.pageNumber
    }

    private static func intCount(_ value: Binding?) -> Int {
        if let int64 = value as? Int64 { return Int(int64) }
        if let int = value as? Int { return int }
        return 0
    }
}
