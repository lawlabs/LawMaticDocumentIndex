import Foundation

public enum UnifiedDocumentSearchMode: String, Sendable, CaseIterable, Identifiable {
    case auto
    case keyword
    case semantic
    case hybrid

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .auto: return "Авто"
        case .keyword: return "По словам"
        case .semantic: return "По смыслу"
        case .hybrid: return "Смешанный"
        }
    }
}

public struct ChunkEmbeddingWorkItem: Sendable {
    public let chunkId: String
    public let content: String

    public init(chunkId: String, content: String) {
        self.chunkId = chunkId
        self.content = content
    }
}

public struct LocalEmbeddingCoverage: Equatable, Sendable {
    public let embeddedChunks: Int
    public let totalChunks: Int

    public init(embeddedChunks: Int, totalChunks: Int) {
        self.embeddedChunks = embeddedChunks
        self.totalChunks = totalChunks
    }

    public var remainingChunks: Int {
        max(totalChunks - embeddedChunks, 0)
    }

    public var isComplete: Bool {
        totalChunks > 0 && embeddedChunks >= totalChunks
    }

    public var fractionCompleted: Double {
        guard totalChunks > 0 else { return 0 }
        return min(max(Double(embeddedChunks) / Double(totalChunks), 0), 1)
    }
}

/// Полнота извлечения и эмбеддингов считаются отдельно: 100% векторов
/// для уже извлечённых чанков не означает, что исходное дело обработано.
public struct DocumentProcessingCoverage: Equatable, Sendable {
    public let documentCount: Int
    public let extractionCounts: [ExtractionStatus: Int]
    public let embedding: LocalEmbeddingCoverage
    public let modelId: String?

    public init(
        documentCount: Int,
        extractionCounts: [ExtractionStatus: Int],
        embedding: LocalEmbeddingCoverage,
        modelId: String? = nil
    ) {
        self.documentCount = documentCount
        self.extractionCounts = extractionCounts
        self.embedding = embedding
        self.modelId = modelId
    }

    public var completeExtractions: Int { extractionCounts[.complete] ?? 0 }
    public var partialExtractions: Int { extractionCounts[.partial] ?? 0 }
    public var pendingExtractions: Int { extractionCounts[.pending] ?? 0 }

    /// Все документы имеют терминальный статус извлечения (не pending/partial).
    public var extractionSettled: Bool {
        documentCount > 0
            && pendingExtractions == 0
            && partialExtractions == 0
            && extractionCounts.values.reduce(0, +) >= documentCount
    }

    /// Полная обработка дела: все документы извлечены как complete и векторы покрыты.
    public var isFullyProcessed: Bool {
        documentCount > 0
            && completeExtractions == documentCount
            && embedding.isComplete
    }

    public var extractionSummary: String {
        let parts = ExtractionStatus.allCases.compactMap { status -> String? in
            let count = extractionCounts[status] ?? 0
            return count > 0 ? "\(status.rawValue)=\(count)" : nil
        }
        if parts.isEmpty {
            return "документов \(documentCount), статусов извлечения нет"
        }
        return "документов \(documentCount); извлечение: " + parts.joined(separator: ", ")
    }
}

public struct LocalEmbeddingSearchDiagnostics: Sendable {
    public let providerId: String
    public let modelId: String
    public let dimension: Int
    public let coverage: LocalEmbeddingCoverage
    /// SQL-проверка покрытия semantic-индекса (`COUNT` по области).
    public let coverageCheckDurationMilliseconds: Int?
    /// Холодная/тёплая подготовка модели (`prepare`), до построения query embedding.
    public let modelPreparationDurationMilliseconds: Int?
    public let queryEmbeddingDurationMilliseconds: Int?
    public let vectorSearchDurationMilliseconds: Int?
    /// Query-текст обрезан по лимиту токенов модели (не windowed-mean).
    public let queryInputTruncated: Bool

    public init(
        providerId: String,
        modelId: String,
        dimension: Int,
        coverage: LocalEmbeddingCoverage,
        coverageCheckDurationMilliseconds: Int?,
        modelPreparationDurationMilliseconds: Int?,
        queryEmbeddingDurationMilliseconds: Int?,
        vectorSearchDurationMilliseconds: Int?,
        queryInputTruncated: Bool = false
    ) {
        self.providerId = providerId
        self.modelId = modelId
        self.dimension = dimension
        self.coverage = coverage
        self.coverageCheckDurationMilliseconds = coverageCheckDurationMilliseconds
        self.modelPreparationDurationMilliseconds = modelPreparationDurationMilliseconds
        self.queryEmbeddingDurationMilliseconds = queryEmbeddingDurationMilliseconds
        self.vectorSearchDurationMilliseconds = vectorSearchDurationMilliseconds
        self.queryInputTruncated = queryInputTruncated
    }
}

/// Разложение общего времени поиска на измеримые стадии.
///
/// Сумма стадий может быть меньше `totalMilliseconds`: между ними остаются
/// короткие участки (выбор провайдера, аллокации). Цель — увидеть,
/// куда уходят секунды hybrid, а не получить бухгалтерское тождество.
public struct DocumentSearchStageTimings: Equatable, Sendable {
    public let totalMilliseconds: Int
    public let coverageCheckMilliseconds: Int?
    public let modelPreparationMilliseconds: Int?
    public let lexicalSearchMilliseconds: Int?
    public let queryEmbeddingMilliseconds: Int?
    public let vectorSearchMilliseconds: Int?
    public let fusionPresentationMilliseconds: Int?

    public init(
        totalMilliseconds: Int,
        coverageCheckMilliseconds: Int?,
        modelPreparationMilliseconds: Int?,
        lexicalSearchMilliseconds: Int?,
        queryEmbeddingMilliseconds: Int?,
        vectorSearchMilliseconds: Int?,
        fusionPresentationMilliseconds: Int?
    ) {
        self.totalMilliseconds = totalMilliseconds
        self.coverageCheckMilliseconds = coverageCheckMilliseconds
        self.modelPreparationMilliseconds = modelPreparationMilliseconds
        self.lexicalSearchMilliseconds = lexicalSearchMilliseconds
        self.queryEmbeddingMilliseconds = queryEmbeddingMilliseconds
        self.vectorSearchMilliseconds = vectorSearchMilliseconds
        self.fusionPresentationMilliseconds = fusionPresentationMilliseconds
    }

    /// Сумма известных стадий; `nil` не участвует.
    public var accountedMilliseconds: Int {
        [
            coverageCheckMilliseconds,
            modelPreparationMilliseconds,
            lexicalSearchMilliseconds,
            queryEmbeddingMilliseconds,
            vectorSearchMilliseconds,
            fusionPresentationMilliseconds
        ]
        .compactMap { $0 }
        .reduce(0, +)
    }

    /// Неразложенный остаток общего времени после известных стадий.
    public var residualMilliseconds: Int {
        max(totalMilliseconds - accountedMilliseconds, 0)
    }
}

public struct DocumentSearchExecution: Sendable {
    public let requestedMode: UnifiedDocumentSearchMode
    public let resolvedMode: UnifiedDocumentSearchMode
    public let results: [ChunkSearchResult]
    public let embeddingDiagnostics: LocalEmbeddingSearchDiagnostics?
    public let searchDurationMilliseconds: Int
    public let stageTimings: DocumentSearchStageTimings

    public init(
        requestedMode: UnifiedDocumentSearchMode,
        resolvedMode: UnifiedDocumentSearchMode,
        results: [ChunkSearchResult],
        embeddingDiagnostics: LocalEmbeddingSearchDiagnostics?,
        searchDurationMilliseconds: Int,
        coverageCheckDurationMilliseconds: Int? = nil,
        lexicalSearchDurationMilliseconds: Int? = nil,
        fusionPresentationDurationMilliseconds: Int? = nil
    ) {
        self.requestedMode = requestedMode
        self.resolvedMode = resolvedMode
        self.results = results
        self.embeddingDiagnostics = embeddingDiagnostics
        self.searchDurationMilliseconds = searchDurationMilliseconds
        let coverageCheckMilliseconds = coverageCheckDurationMilliseconds
            ?? embeddingDiagnostics?.coverageCheckDurationMilliseconds
        self.stageTimings = DocumentSearchStageTimings(
            totalMilliseconds: searchDurationMilliseconds,
            coverageCheckMilliseconds: coverageCheckMilliseconds,
            modelPreparationMilliseconds:
                embeddingDiagnostics?.modelPreparationDurationMilliseconds,
            lexicalSearchMilliseconds: lexicalSearchDurationMilliseconds,
            queryEmbeddingMilliseconds:
                embeddingDiagnostics?.queryEmbeddingDurationMilliseconds,
            vectorSearchMilliseconds:
                embeddingDiagnostics?.vectorSearchDurationMilliseconds,
            fusionPresentationMilliseconds: fusionPresentationDurationMilliseconds
        )
    }
}

public enum DocumentSearchModeResolver: Sendable {
    public static func resolve(
        requestedMode: UnifiedDocumentSearchMode,
        embeddingProviderAvailable: Bool,
        coverage: LocalEmbeddingCoverage?
    ) -> UnifiedDocumentSearchMode {
        guard requestedMode == .auto else { return requestedMode }
        guard embeddingProviderAvailable, coverage?.isComplete == true else {
            return .keyword
        }
        return .hybrid
    }
}

public enum ChunkSearchSource: String, Sendable {
    case lexical
    case semantic
    case hybrid
}

public struct ChunkSearchResult: Identifiable, Sendable {
    public let id: String
    public let chunkId: String
    public let documentId: String
    public let fileURL: URL
    public let fileName: String
    public let relativePath: String
    public let variantType: String
    /// SHA-256 полного извлечённого текста варианта. Одинаковое значение у
    /// разных documentId означает точную копию документа.
    public let documentTextHash: String?
    public let content: String
    public let utf16Start: Int
    public let utf16End: Int
    public let pageNumber: Int?
    public let score: Float
    public let source: ChunkSearchSource

    public init(
        id: String,
        chunkId: String,
        documentId: String,
        fileURL: URL,
        fileName: String,
        relativePath: String,
        variantType: String,
        documentTextHash: String?,
        content: String,
        utf16Start: Int,
        utf16End: Int,
        pageNumber: Int?,
        score: Float,
        source: ChunkSearchSource
    ) {
        self.id = id
        self.chunkId = chunkId
        self.documentId = documentId
        self.fileURL = fileURL
        self.fileName = fileName
        self.relativePath = relativePath
        self.variantType = variantType
        self.documentTextHash = documentTextHash
        self.content = content
        self.utf16Start = utf16Start
        self.utf16End = utf16End
        self.pageNumber = pageNumber
        self.score = score
        self.source = source
    }
}

/// Объединяет ранги двух поисковых ветвей без смешивания несопоставимых
/// абсолютных шкал BM25 и cosine similarity.
public enum ReciprocalRankFusion: Sendable {
    public static func merge(
        lexical: [ChunkSearchResult],
        semantic: [ChunkSearchResult],
        k: Float = 60,
        limit: Int
    ) -> [ChunkSearchResult] {
        var scores: [String: Float] = [:]
        var values: [String: ChunkSearchResult] = [:]

        var lexicalIds: Set<String> = []
        var semanticIds: Set<String> = []
        let uniqueLexical = lexical.filter { lexicalIds.insert($0.chunkId).inserted }
        let uniqueSemantic = semantic.filter { semanticIds.insert($0.chunkId).inserted }
        for (rank, result) in uniqueLexical.enumerated() {
            scores[result.chunkId, default: 0] += 1 / (k + Float(rank + 1))
            values[result.chunkId] = result
        }
        for (rank, result) in uniqueSemantic.enumerated() {
            scores[result.chunkId, default: 0] += 1 / (k + Float(rank + 1))
            values[result.chunkId] = result
        }

        return scores
            .sorted {
                if $0.value != $1.value { return $0.value > $1.value }
                return $0.key < $1.key
            }
            .prefix(max(limit, 0))
            .compactMap { chunkId, score in
                guard let value = values[chunkId] else { return nil }
                return ChunkSearchResult(
                    id: value.id,
                    chunkId: value.chunkId,
                    documentId: value.documentId,
                    fileURL: value.fileURL,
                    fileName: value.fileName,
                    relativePath: value.relativePath,
                    variantType: value.variantType,
                    documentTextHash: value.documentTextHash,
                    content: value.content,
                    utf16Start: value.utf16Start,
                    utf16End: value.utf16End,
                    pageNumber: value.pageNumber,
                    score: score,
                    source: .hybrid
                )
            }
    }
}
