import Foundation
import Testing
@testable import LawMaticDocumentIndex

@Test("RRF поднимает результат, найденный обеими ветвями")
func rrfПоднимаетРезультатНайденныйОбеимиВетвями() {
    func result(_ id: String, score: Float, source: ChunkSearchSource) -> ChunkSearchResult {
        ChunkSearchResult(
            id: id,
            chunkId: id,
            documentId: "document-\(id)",
            fileURL: URL(fileURLWithPath: "/tmp/\(id).txt"),
            fileName: "\(id).txt",
            relativePath: "\(id).txt",
            variantType: "original",
            documentTextHash: nil,
            content: id,
            utf16Start: 0,
            utf16End: id.utf16.count,
            pageNumber: nil,
            score: score,
            source: source
        )
    }

    let lexical = [
        result("lexical-only", score: -0.1, source: .lexical),
        result("shared", score: -0.2, source: .lexical)
    ]
    let semantic = [
        result("semantic-only", score: 0.9, source: .semantic),
        result("shared", score: 0.8, source: .semantic)
    ]
    let fused = ReciprocalRankFusion.merge(
        lexical: lexical,
        semantic: semantic,
        limit: 3
    )

    #expect(fused.first?.chunkId == "shared", "совпадение двух ветвей получает первый ранг")
    #expect(fused.allSatisfy { $0.source == .hybrid }, "источник объединённой выдачи помечен hybrid")
    #expect(
        ReciprocalRankFusion.merge(lexical: lexical, semantic: semantic, limit: 0).count == 0,
        "нулевой limit возвращает пустую выдачу"
    )
}

@Test("Contentless FTS чанков поддерживает адресное удаление")
func contentlessFtsЧанковПоддерживаетАдресноеУдаление() throws {
    let database = try TestDatabase()
    try database.execute("""
        CREATE TABLE chunk_records (
            fts_rowid INTEGER PRIMARY KEY AUTOINCREMENT,
            id TEXT NOT NULL UNIQUE,
            content TEXT NOT NULL
        );
        CREATE VIRTUAL TABLE chunk_fts USING fts5(
            file_name_norm, content_norm, content='', contentless_delete=1
        );
        INSERT INTO chunk_records(id, content) VALUES ('chunk-1', 'Исковое заявление');
        INSERT INTO chunk_fts(rowid, file_name_norm, content_norm)
            VALUES (last_insert_rowid(), 'иск docx', 'исков заявлен');
    """)
    #expect(
        try database.scalarInt("SELECT count(*) FROM chunk_fts WHERE chunk_fts MATCH 'исков*'") == 1,
        "чанк находится в contentless FTS"
    )
    try database.execute("""
        DELETE FROM chunk_fts
        WHERE rowid IN (SELECT fts_rowid FROM chunk_records WHERE id = 'chunk-1');
        DELETE FROM chunk_records WHERE id = 'chunk-1';
    """)
    #expect(
        try database.scalarInt("SELECT count(*) FROM chunk_fts WHERE chunk_fts MATCH 'исков*'") == 0,
        "адресное удаление очищает индекс"
    )
}

@Test("Semantic-покрытие не принимает частичный индекс за полный")
func semanticПокрытиеНеПринимаетЧастичныйИндексЗаПолный() {
    let empty = LocalEmbeddingCoverage(embeddedChunks: 0, totalChunks: 0)
    #expect(!empty.isComplete, "пустая область не считается готовой")
    #expect(empty.fractionCompleted == 0, "пустая область имеет нулевое покрытие")

    let partial = LocalEmbeddingCoverage(embeddedChunks: 184, totalChunks: 706)
    #expect(!partial.isComplete, "частичный индекс не считается готовым")
    #expect(partial.remainingChunks == 522, "остаток частичного индекса вычисляется точно")

    let complete = LocalEmbeddingCoverage(embeddedChunks: 706, totalChunks: 706)
    #expect(complete.isComplete, "полностью построенный индекс считается готовым")
    #expect(complete.fractionCompleted == 1, "полный индекс имеет покрытие 100%")
}

@Test("Auto-поиск включает hybrid только для полного индекса")
func autoПоискВключаетHybridТолькоДляПолногоИндекса() {
    let partial = LocalEmbeddingCoverage(embeddedChunks: 184, totalChunks: 706)
    let complete = LocalEmbeddingCoverage(embeddedChunks: 706, totalChunks: 706)

    #expect(
        DocumentSearchModeResolver.resolve(
            requestedMode: .auto,
            embeddingProviderAvailable: true,
            coverage: complete
        ) == .hybrid,
        "полностью проиндексированная область использует hybrid"
    )
    #expect(
        DocumentSearchModeResolver.resolve(
            requestedMode: .auto,
            embeddingProviderAvailable: true,
            coverage: partial
        ) == .keyword,
        "частичный индекс не используется как semantic"
    )
    #expect(
        DocumentSearchModeResolver.resolve(
            requestedMode: .auto,
            embeddingProviderAvailable: false,
            coverage: nil
        ) == .keyword,
        "без локального provider auto остаётся keyword"
    )
    #expect(
        DocumentSearchModeResolver.resolve(
            requestedMode: .semantic,
            embeddingProviderAvailable: false,
            coverage: nil
        ) == .semantic,
        "явный semantic не скрывает ошибку fallback-режимом"
    )
}

@Test("Coverage SQL объединяет total и embedded в один проход")
func coverageSQLОбъединяетTotalИEmbeddedВОдинПроход() throws {
    let sql = EmbeddingCoverageSQL.combinedCountSQL(
        scopeSQL: " AND case_records.workspace_root_id = ?"
    )
    #expect(
        sql.contains("COUNT(chunk_embeddings.chunk_id)"),
        "embedded считается через LEFT JOIN embeddings"
    )
    #expect(
        sql.contains("LEFT JOIN chunk_embeddings"),
        "embeddings присоединяются LEFT JOIN с фильтром model_id"
    )
    #expect(
        sql.contains("chunk_embeddings.model_id = ?"),
        "model_id задаётся в ON, а не отсекает чанки без embedding"
    )
    #expect(
        !sql.contains("FROM chunk_embeddings\n                    JOIN chunk_records"),
        "отдельный COUNT по chunk_embeddings больше не используется"
    )

    let database = try TestDatabase()
    try database.execute("""
        CREATE TABLE chunk_records (
            id TEXT PRIMARY KEY,
            document_id TEXT,
            case_id TEXT,
            variant_type TEXT
        );
        CREATE TABLE chunk_embeddings (
            chunk_id TEXT NOT NULL,
            model_id TEXT NOT NULL,
            PRIMARY KEY (chunk_id, model_id)
        );
    """)
    try database.addCase(id: "case-a", workspaceRootId: "ws-a", rootPath: "/ws")
    try database.addDocument(
        id: "doc-1",
        caseId: "case-a",
        rootFolderPath: "/ws",
        folderPath: "Авилон",
        relativePath: "Авилон/иск.docx",
        fileName: "иск.docx",
        text: "требования"
    )
    try database.run(
        "INSERT INTO chunk_records (id, document_id, case_id, variant_type) VALUES (?, ?, ?, 'original')",
        ["c1", "doc-1", "case-a"]
    )
    try database.run(
        "INSERT INTO chunk_records (id, document_id, case_id, variant_type) VALUES (?, ?, ?, 'original')",
        ["c2", "doc-1", "case-a"]
    )
    try database.run(
        "INSERT INTO chunk_embeddings (chunk_id, model_id) VALUES (?, ?)",
        ["c1", "model-x"]
    )

    let counts = try database.scalarTwoInts(
        EmbeddingCoverageSQL.combinedCountSQL(
            scopeSQL: " AND case_records.workspace_root_id = ?"
        ),
        ["model-x", "ws-a"]
    )
    #expect(counts.0 == 2, "total считает все original-чанки области")
    #expect(counts.1 == 1, "embedded считает только чанки выбранной модели")
}

@Test("Кэш coverage отдаёт значение до инвалидации")
func кэшCoverageОтдаётЗначениеДоИнвалидации() {
    let cache = EmbeddingCoverageCache()
    let key = EmbeddingCoverageCache.key(
        modelId: "model-x",
        workspaceRootId: "ws-a",
        relativePath: "Авилон"
    )
    let value = LocalEmbeddingCoverage(embeddedChunks: 706, totalChunks: 706)

    #expect(cache.coverage(forKey: key) == nil, "пустой кэш не отдаёт coverage")
    cache.store(value, forKey: key)
    #expect(
        cache.coverage(forKey: key) == value,
        "повторный lookup возвращает сохранённое покрытие"
    )
    cache.invalidateAll()
    #expect(
        cache.coverage(forKey: key) == nil,
        "после инвалидации кэш пуст"
    )
}

@Test("Разложенная диагностика времени hybrid-поиска")
func разложеннаяДиагностикаВремениHybridПоиска() {
    let coverage = LocalEmbeddingCoverage(embeddedChunks: 10, totalChunks: 10)
    let embedding = LocalEmbeddingSearchDiagnostics(
        providerId: "mlx",
        modelId: "test-model",
        dimension: 8,
        coverage: coverage,
        coverageCheckDurationMilliseconds: 1_420,
        modelPreparationDurationMilliseconds: 800,
        queryEmbeddingDurationMilliseconds: 37,
        vectorSearchDurationMilliseconds: 31
    )
    let execution = DocumentSearchExecution(
        requestedMode: .auto,
        resolvedMode: .hybrid,
        results: [],
        embeddingDiagnostics: embedding,
        searchDurationMilliseconds: 2_400,
        coverageCheckDurationMilliseconds: 1_420,
        lexicalSearchDurationMilliseconds: 48,
        fusionPresentationDurationMilliseconds: 12
    )
    let timings = execution.stageTimings

    #expect(timings.totalMilliseconds == 2_400, "total совпадает с searchDuration")
    #expect(timings.coverageCheckMilliseconds == 1_420, "SQL coverage выделен отдельно")
    #expect(timings.modelPreparationMilliseconds == 800, "prepare выделен отдельно")
    #expect(timings.lexicalSearchMilliseconds == 48, "лексическая ветвь замерена")
    #expect(timings.queryEmbeddingMilliseconds == 37, "query embedding сохранён")
    #expect(timings.vectorSearchMilliseconds == 31, "vector scan сохранён")
    #expect(timings.fusionPresentationMilliseconds == 12, "RRF+presentation замерены")
    #expect(
        timings.accountedMilliseconds == 1_420 + 800 + 48 + 37 + 31 + 12,
        "сумма известных стадий считается без nil"
    )
    #expect(
        timings.residualMilliseconds == 2_400 - timings.accountedMilliseconds,
        "residual показывает неразложенный остаток"
    )
    #expect(
        timings.coverageCheckMilliseconds! + timings.modelPreparationMilliseconds!
            + timings.queryEmbeddingMilliseconds!
            + timings.vectorSearchMilliseconds!
            < timings.totalMilliseconds,
        "стадии coverage/embedding не маскируют общее время поиска"
    )

    let keywordOnly = DocumentSearchExecution(
        requestedMode: .keyword,
        resolvedMode: .keyword,
        results: [],
        embeddingDiagnostics: nil,
        searchDurationMilliseconds: 80,
        coverageCheckDurationMilliseconds: nil,
        lexicalSearchDurationMilliseconds: 70,
        fusionPresentationDurationMilliseconds: 5
    )
    #expect(
        keywordOnly.stageTimings.modelPreparationMilliseconds == nil as Int?,
        "keyword без semantic не сообщает prepare"
    )
    #expect(
        keywordOnly.stageTimings.coverageCheckMilliseconds == nil as Int?,
        "keyword без provider не сообщает coverage"
    )
    #expect(
        keywordOnly.stageTimings.accountedMilliseconds == 75,
        "keyword учитывает только lexical и presentation"
    )
    #expect(
        keywordOnly.stageTimings.residualMilliseconds == 5,
        "keyword residual не отрицательный"
    )
}
