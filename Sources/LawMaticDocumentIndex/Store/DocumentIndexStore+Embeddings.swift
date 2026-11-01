import Foundation
import SQLite

public struct EmbeddingCandidate: Sendable {
    public let chunkRowid: Int64
    public let scale: Float
    public let vector: Data

    public init(chunkRowid: Int64, scale: Float, vector: Data) {
        self.chunkRowid = chunkRowid
        self.scale = scale
        self.vector = vector
    }
}

public struct ChunkEmbeddingBatchItem: Sendable {
    public let chunkRowid: Int64
    public let embedding: QuantizedEmbedding

    public init(chunkRowid: Int64, embedding: QuantizedEmbedding) {
        self.chunkRowid = chunkRowid
        self.embedding = embedding
    }
}

extension DocumentIndexStore {
    @discardableResult
    public func registerEmbeddingModel(
        _ descriptor: LocalEmbeddingDescriptor,
        quantization: String = "int8"
    ) throws -> EmbeddingModelRecord {
        try write { db in
            let now = Self.iso(Date())
            if let existing = try Self.fetchEmbeddingModel(db, id: descriptor.modelId),
               existing.dimension != descriptor.dimension || existing.quantization != quantization || existing.provider != descriptor.providerId {
                throw DocumentIndexError.invalidArgument("model_id уже зарегистрирован с другими параметрами")
            }
            try db.run(
                """
                INSERT INTO embedding_models(model_id, provider, dim, quantization, created_at_iso)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(model_id) DO UPDATE SET
                    provider = excluded.provider,
                    dim = excluded.dim,
                    quantization = excluded.quantization
                """,
                descriptor.modelId,
                descriptor.providerId,
                Int64(descriptor.dimension),
                quantization,
                now
            )
            guard let record = try Self.fetchEmbeddingModel(db, id: descriptor.modelId) else {
                throw DocumentIndexError.notFound(descriptor.modelId)
            }
            return record
        }
    }

    public func embeddingModels() throws -> [EmbeddingModelRecord] {
        let db = try db()
        var records: [EmbeddingModelRecord] = []
        for row in try db.prepare(
            """
            SELECT model_id, provider, dim, quantization, created_at_iso
            FROM embedding_models
            ORDER BY created_at_iso, model_id
            """
        ) {
            if let record = Self.embeddingModel(from: RowReader(row)) {
                records.append(record)
            }
        }
        return records
    }

    public func embeddingModel(id: String) throws -> EmbeddingModelRecord? {
        try Self.fetchEmbeddingModel(try db(), id: id)
    }

    /// Одна транзакция, `INSERT OR REPLACE`. Размерность каждого вектора должна совпадать с `dim` модели.
    public func storeChunkEmbeddings(_ items: [ChunkEmbeddingBatchItem], modelId: String) throws {
        if items.isEmpty { return }
        try write { db in
            guard let model = try Self.fetchEmbeddingModel(db, id: modelId) else {
                throw DocumentIndexError.notFound(modelId)
            }
            for item in items {
                guard item.embedding.dimension == model.dimension,
                      item.embedding.bytes.count == model.dimension else {
                    throw DocumentIndexError.invalidArgument(
                        "размерность вектора \(item.embedding.dimension) не совпадает с моделью \(model.dimension)"
                    )
                }
            }
            let now = Self.iso(Date())
            let statement = try db.prepare(
                """
                INSERT OR REPLACE INTO chunk_embeddings(chunk_rowid, model_id, scale, vector, created_at_iso)
                VALUES (?, ?, ?, ?, ?)
                """
            )
            for item in items {
                try statement.run(
                    item.chunkRowid,
                    modelId,
                    Double(item.embedding.scale),
                    SQLite.Blob(bytes: [UInt8](item.embedding.bytes)),
                    now
                )
            }
        }
    }

    public func deleteEmbeddings(modelId: String) throws {
        try write { db in
            try db.run("DELETE FROM chunk_embeddings WHERE model_id = ?", modelId)
            return
        }
    }

    /// Один SQL: `COUNT(DISTINCT)` чанков текущих вариантов области и эмбеддингов модели.
    /// Копии одного `text_hash` не удваивают ни общее число, ни покрытие.
    public func embeddingCoverage(
        in scope: SearchScope,
        modelId: String,
        variantFilter: DocumentTextVariantFilter = .original
    ) throws -> LocalEmbeddingCoverage {
        let db = try db()
        let query = EmbeddingScopeSQL.coverage(scope: scope, modelId: modelId, variantFilter: variantFilter, includeCaseLinks: try currentCapabilities().supportsExplicitCaseDocuments)
        for row in try db.prepare(query.sql, query.bindings) {
            let reader = RowReader(row)
            return LocalEmbeddingCoverage(
                embeddedChunks: reader.int(1) ?? 0,
                totalChunks: reader.int(0) ?? 0
            )
        }
        return LocalEmbeddingCoverage(embeddedChunks: 0, totalChunks: 0)
    }

    /// Извлечение и эмбеддинги в одной сводке: UI не должен смешивать эти проценты.
    public func processingCoverage(
        in scope: SearchScope,
        modelId: String?
    ) throws -> DocumentProcessingCoverage {
        let documents = try documentCount(in: scope)
        let extraction = try extractionStatusCounts(in: scope)
        let embedding: LocalEmbeddingCoverage
        if let modelId {
            embedding = try embeddingCoverage(in: scope, modelId: modelId)
        } else {
            embedding = LocalEmbeddingCoverage(embeddedChunks: 0, totalChunks: 0)
        }
        return DocumentProcessingCoverage(
            documentCount: documents,
            extractionCounts: extraction,
            embedding: embedding,
            modelId: modelId
        )
    }

    public func defaultEmbeddingModelId() throws -> String? {
        try metadata(DocumentIndexSchema.MetadataKey.defaultEmbeddingModelId)
    }

    public func setDefaultEmbeddingModelId(_ modelId: String) throws {
        try setMetadata(DocumentIndexSchema.MetadataKey.defaultEmbeddingModelId, modelId)
    }

    /// Непроиндексированные чанки области; текст режется из `texts.content` один раз на `text_hash`.
    public func chunksWithoutEmbeddings(
        in scope: SearchScope,
        modelId: String,
        variantFilter: DocumentTextVariantFilter = .original,
        limit: Int = 256
    ) throws -> [(rowid: Int64, item: ChunkEmbeddingWorkItem)] {
        let db = try db()
        let query = EmbeddingScopeSQL.chunksWithoutEmbeddings(
            scope: scope,
            modelId: modelId,
            variantFilter: variantFilter,
            limit: limit, includeCaseLinks: try currentCapabilities().supportsExplicitCaseDocuments
        )
        var metas: [(rowid: Int64, id: String, textHash: String, utf16Start: Int, utf16End: Int)] = []
        var hashes: [String] = []
        var seenHashes = Set<String>()
        for row in try db.prepare(query.sql, query.bindings) {
            let reader = RowReader(row)
            guard let rowid = reader.int64(0),
                  let id = reader.string(1),
                  let textHash = reader.string(2),
                  let utf16Start = reader.int(3),
                  let utf16End = reader.int(4) else {
                continue
            }
            metas.append((rowid, id, textHash, utf16Start, utf16End))
            if seenHashes.insert(textHash).inserted {
                hashes.append(textHash)
            }
        }
        let contents = try Self.loadTextContents(db, hashes: hashes)
        return metas.map { meta in
            let slice = Self.slice(
                contents[meta.textHash] ?? "",
                utf16Start: meta.utf16Start,
                utf16End: meta.utf16End
            )
            return (meta.rowid, ChunkEmbeddingWorkItem(chunkId: meta.id, content: slice))
        }
    }

    /// Чанки одного текста без эмбеддинга модели; `texts.content` читается один раз.
    public func chunksWithoutEmbeddings(
        textHash: String,
        modelId: String
    ) throws -> [(rowid: Int64, item: ChunkEmbeddingWorkItem)] {
        let db = try db()
        var metas: [(rowid: Int64, id: String, utf16Start: Int, utf16End: Int)] = []
        for row in try db.prepare(
            """
            SELECT c.rowid, c.id, c.utf16_start, c.utf16_end
            FROM chunks c
            LEFT JOIN chunk_embeddings e
              ON e.chunk_rowid = c.rowid AND e.model_id = ?
            WHERE c.text_hash = ?
              AND e.chunk_rowid IS NULL
              AND EXISTS (
                SELECT 1 FROM text_variants tv
                WHERE tv.text_hash = c.text_hash AND tv.is_current = 1
              )
            ORDER BY c.chunk_index
            """,
            modelId,
            textHash
        ) {
            let reader = RowReader(row)
            guard let rowid = reader.int64(0),
                  let id = reader.string(1),
                  let utf16Start = reader.int(2),
                  let utf16End = reader.int(3) else {
                continue
            }
            metas.append((rowid, id, utf16Start, utf16End))
        }
        let contents = try Self.loadTextContents(db, hashes: metas.isEmpty ? [] : [textHash])
        let content = contents[textHash] ?? ""
        return metas.map { meta in
            (
                meta.rowid,
                ChunkEmbeddingWorkItem(
                    chunkId: meta.id,
                    content: Self.slice(content, utf16Start: meta.utf16Start, utf16End: meta.utf16End)
                )
            )
        }
    }

    /// Только векторы области: без `texts` и без содержимого чанка.
    public func embeddingCandidates(
        in scope: SearchScope,
        modelId: String,
        variantFilter: DocumentTextVariantFilter = .original
    ) throws -> [EmbeddingCandidate] {
        let db = try db()
        let query = EmbeddingScopeSQL.candidates(scope: scope, modelId: modelId, variantFilter: variantFilter, includeCaseLinks: try currentCapabilities().supportsExplicitCaseDocuments)
        var result: [EmbeddingCandidate] = []
        for row in try db.prepare(query.sql, query.bindings) {
            let reader = RowReader(row)
            guard let rowid = reader.int64(0),
                  let vector = reader.blob(2) else {
                continue
            }
            let scale = Float(reader.double(1) ?? 0)
            result.append(EmbeddingCandidate(chunkRowid: rowid, scale: scale, vector: vector))
        }
        return result
    }

    public func embeddingCount(modelId: String) throws -> Int {
        let value = try db().scalar("SELECT COUNT(*) FROM chunk_embeddings WHERE model_id = ?", modelId)
        if let int64 = value as? Int64 { return Int(int64) }
        if let int = value as? Int { return int }
        return 0
    }

    // MARK: Чтение

    static func fetchEmbeddingModel(_ db: SQLite.Connection, id: String) throws -> EmbeddingModelRecord? {
        for row in try db.prepare(
            """
            SELECT model_id, provider, dim, quantization, created_at_iso
            FROM embedding_models WHERE model_id = ?
            """,
            id
        ) {
            return embeddingModel(from: RowReader(row))
        }
        return nil
    }

    private static func embeddingModel(from reader: RowReader) -> EmbeddingModelRecord? {
        guard let modelId = reader.string(0),
              let provider = reader.string(1),
              let dimension = reader.int(2),
              let quantization = reader.string(3),
              let createdAt = reader.date(4) else {
            return nil
        }
        return EmbeddingModelRecord(
            modelId: modelId,
            provider: provider,
            dimension: dimension,
            quantization: quantization,
            createdAt: createdAt
        )
    }

    private static func loadTextContents(_ db: SQLite.Connection, hashes: [String]) throws -> [String: String] {
        guard !hashes.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: hashes.count).joined(separator: ", ")
        var contents: [String: String] = [:]
        let hashBindings: [Binding] = hashes.map { $0 }
        for row in try db.prepare(
            "SELECT text_hash, content FROM texts WHERE text_hash IN (\(placeholders))",
            hashBindings
        ) {
            let reader = RowReader(row)
            if let hash = reader.string(0), let content = reader.string(1) {
                contents[hash] = content
            }
        }
        return contents
    }
}

// MARK: - SQL областей

/// Сборка запросов покрытия / кандидатов по области.
enum EmbeddingScopeSQL {
    struct Query {
        let sql: String
        let bindings: [Binding]
    }

    static func coverage(
        scope: SearchScope,
        modelId: String,
        variantFilter: DocumentTextVariantFilter, includeCaseLinks: Bool = false
    ) -> Query {
        let part = join(scope: scope, variantFilter: variantFilter, embeddings: .left, modelId: modelId, includeCaseLinks: includeCaseLinks)
        return Query(
            sql: """
                \(part.withClause)SELECT COUNT(DISTINCT c.rowid), COUNT(DISTINCT e.chunk_rowid)
                \(part.fromSQL)
                WHERE \(part.whereSQL)
                """,
            bindings: part.bindings
        )
    }

    static func chunksWithoutEmbeddings(
        scope: SearchScope,
        modelId: String,
        variantFilter: DocumentTextVariantFilter,
        limit: Int, includeCaseLinks: Bool = false
    ) -> Query {
        let part = join(scope: scope, variantFilter: variantFilter, embeddings: .left, modelId: modelId, includeCaseLinks: includeCaseLinks)
        return Query(
            sql: """
                \(part.withClause)SELECT DISTINCT c.rowid, c.id, c.text_hash, c.utf16_start, c.utf16_end
                \(part.fromSQL)
                WHERE \(part.whereSQL) AND e.chunk_rowid IS NULL
                ORDER BY c.text_hash, c.chunk_index
                LIMIT \(max(limit, 0))
                """,
            bindings: part.bindings
        )
    }

    static func candidates(
        scope: SearchScope,
        modelId: String,
        variantFilter: DocumentTextVariantFilter, includeCaseLinks: Bool = false
    ) -> Query {
        if case .everything = scope {
            // Горячий путь: индекс (model_id, chunk_rowid), без JOIN на documents и texts.
            return Query(
                sql: """
                    SELECT e.chunk_rowid, e.scale, e.vector
                    FROM chunk_embeddings e
                    WHERE e.model_id = ?
                      AND EXISTS (
                        SELECT 1 FROM chunks c
                        JOIN text_variants tv
                          ON tv.text_hash = c.text_hash AND tv.is_current = 1\(variantSQL(variantFilter))
                        WHERE c.rowid = e.chunk_rowid
                      )
                    """,
                bindings: [modelId]
            )
        }
        let part = join(scope: scope, variantFilter: variantFilter, embeddings: .inner, modelId: modelId, includeCaseLinks: includeCaseLinks)
        return Query(
            sql: """
                \(part.withClause)SELECT DISTINCT e.chunk_rowid, e.scale, e.vector
                \(part.fromSQL)
                WHERE \(part.whereSQL)
                """,
            bindings: part.bindings
        )
    }

    static func uncoveredTextHashes(
        scope: SearchScope,
        modelId: String,
        variantFilter: DocumentTextVariantFilter, includeCaseLinks: Bool = false
    ) -> Query {
        let part = join(scope: scope, variantFilter: variantFilter, embeddings: .left, modelId: modelId, includeCaseLinks: includeCaseLinks)
        return Query(
            sql: """
                \(part.withClause)SELECT DISTINCT c.text_hash
                \(part.fromSQL)
                WHERE \(part.whereSQL) AND e.chunk_rowid IS NULL
                """,
            bindings: part.bindings
        )
    }

    private enum EmbeddingsJoin {
        case left
        case inner
    }

    private struct JoinPart {
        let withClause: String
        let fromSQL: String
        let whereSQL: String
        let bindings: [Binding]
    }

    private static func join(
        scope: SearchScope,
        variantFilter: DocumentTextVariantFilter,
        embeddings: EmbeddingsJoin,
        modelId: String, includeCaseLinks: Bool = false
    ) -> JoinPart {
        let scopeSQL = ScopeSQL(scope: scope, includeCaseLinks: includeCaseLinks)
        let variant = variantSQL(variantFilter)
        let embedSQL: String
        switch embeddings {
        case .left:
            embedSQL = "LEFT JOIN chunk_embeddings e ON e.chunk_rowid = c.rowid AND e.model_id = ?"
        case .inner:
            embedSQL = "JOIN chunk_embeddings e ON e.chunk_rowid = c.rowid AND e.model_id = ?"
        }

        if case .everything = scope {
            return JoinPart(
                withClause: "",
                fromSQL: """
                    FROM chunks c
                    JOIN text_variants tv
                      ON tv.text_hash = c.text_hash AND tv.is_current = 1\(variant)
                    \(embedSQL)
                    """,
                whereSQL: "1 = 1",
                bindings: [modelId]
            )
        }

        // Старт с documents, чтобы рекурсивная папка шла через idx_documents_folder, а не SCAN d.
        let fromSQL = """
            FROM documents d
            JOIN text_variants tv
              ON tv.document_id = d.id AND tv.is_current = 1\(variant)
            JOIN chunks c ON c.text_hash = tv.text_hash
            \(embedSQL)
            """
        // Порядок плейсхолдеров как в SQL: CTE области → model_id в JOIN → предикат области.
        let modelBinding: Binding = modelId
        return JoinPart(
            withClause: scopeSQL.withClause,
            fromSQL: fromSQL,
            whereSQL: scopeSQL.predicate,
            bindings: scopeSQL.cteBindings + [modelBinding] + scopeSQL.predicateBindings
        )
    }

    private static func variantSQL(_ filter: DocumentTextVariantFilter) -> String {
        switch filter {
        case .original: return " AND tv.variant_type = 'original'"
        case .anonymized: return " AND tv.variant_type = 'anonymized'"
        case .all: return ""
        }
    }
}
