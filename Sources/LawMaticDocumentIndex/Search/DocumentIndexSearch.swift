import Foundation

/// Поисковый фасад v2: keyword / semantic / hybrid над `DocumentIndexStore`.
///
/// Без провайдера доступен только keyword. Обращения к store сериализует актор
/// хранилища; query-эмбеддинг и лексическую ветвь hybrid можно считать параллельно.
public actor DocumentIndexSearch {
    public struct EmbeddingConfiguration: Sendable {
        public let provider: any LocalEmbeddingProvider
        public var descriptor: LocalEmbeddingDescriptor { provider.descriptor }

        public init(provider: any LocalEmbeddingProvider) {
            self.provider = provider
        }
    }

    public enum CoveragePolicy: Sendable {
        /// Явный semantic/hybrid при неполном покрытии уходит в keyword.
        case requireComplete
        /// Выполняем запрошенный режим; неполнота видна в диагностике.
        case allowPartial
    }

    public struct DocumentSearchRequest: Sendable {
        public var query: String
        public var scope: SearchScope
        public var mode: UnifiedDocumentSearchMode
        public var variantFilter: DocumentTextVariantFilter
        public var limit: Int
        public var coveragePolicy: CoveragePolicy

        public init(
            query: String,
            scope: SearchScope,
            mode: UnifiedDocumentSearchMode = .auto,
            variantFilter: DocumentTextVariantFilter = .original,
            limit: Int = 20,
            coveragePolicy: CoveragePolicy = .allowPartial
        ) {
            self.query = query
            self.scope = scope
            self.mode = mode
            self.variantFilter = variantFilter
            self.limit = limit
            self.coveragePolicy = coveragePolicy
        }
    }

    private let store: DocumentIndexStore
    private let embedding: EmbeddingConfiguration?

    public init(store: DocumentIndexStore, embedding: EmbeddingConfiguration? = nil) {
        self.store = store
        self.embedding = embedding
    }

    public func search(_ request: DocumentSearchRequest) async throws -> DocumentSearchExecution {
        let startedAt = Date()
        let trimmed = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return Self.execution(
                request: request,
                resolved: request.mode == .auto ? .keyword : request.mode,
                results: [],
                diagnostics: nil,
                startedAt: startedAt
            )
        }

        let limit = max(request.limit, 0)
        var coverage: LocalEmbeddingCoverage?
        var coverageMs: Int?

        if request.mode != .keyword, let embedding {
            let coverageStartedAt = Date()
            coverage = try await store.embeddingCoverage(
                in: request.scope,
                modelId: embedding.descriptor.modelId,
                variantFilter: request.variantFilter
            )
            coverageMs = Self.elapsedMilliseconds(since: coverageStartedAt)
        }

        let resolved = Self.resolveMode(
            request: request,
            providerAvailable: embedding != nil,
            coverage: coverage
        )

        do {
            switch resolved {
            case .keyword:
                return try await runKeyword(
                    request: request,
                    resolved: .keyword,
                    limit: limit,
                    coverage: coverage,
                    coverageMs: coverageMs,
                    startedAt: startedAt
                )
            case .semantic:
                return try await runSemantic(
                    request: request,
                    resolved: .semantic,
                    limit: limit,
                    coverage: coverage,
                    coverageMs: coverageMs,
                    startedAt: startedAt
                )
            case .hybrid:
                return try await runHybrid(
                    request: request,
                    limit: limit,
                    coverage: coverage,
                    coverageMs: coverageMs,
                    startedAt: startedAt
                )
            case .auto:
                return try await runKeyword(
                    request: request,
                    resolved: .keyword,
                    limit: limit,
                    coverage: coverage,
                    coverageMs: coverageMs,
                    startedAt: startedAt
                )
            }
        } catch {
            // В DocumentSearchExecution нет поля ошибки: при .auto не маскируем
            // чужой режим, а отдаём keyword и resolvedMode = .keyword. Падение самой
            // keyword-ветви повторять бессмысленно — пробрасываем.
            guard request.mode == .auto, resolved != .keyword else { throw error }
            return try await runKeyword(
                request: request,
                resolved: .keyword,
                limit: limit,
                coverage: coverage,
                coverageMs: coverageMs,
                startedAt: startedAt
            )
        }
    }

    public func context(
        chunkId: String,
        documentId: String? = nil,
        surroundingChunks: Int = 1
    ) async throws -> [ChunkSearchResult] {
        if let documentId, !documentId.isEmpty {
            return try await store.chunkContext(
                chunkId: chunkId,
                documentId: documentId,
                surroundingChunks: surroundingChunks
            )
        }
        return try await store.chunkContext(
            chunkId: chunkId,
            surroundingChunks: surroundingChunks
        )
    }

    // MARK: Режимы

    private static func resolveMode(
        request: DocumentSearchRequest,
        providerAvailable: Bool,
        coverage: LocalEmbeddingCoverage?
    ) -> UnifiedDocumentSearchMode {
        if request.mode == .auto {
            return DocumentSearchModeResolver.resolve(
                requestedMode: .auto,
                embeddingProviderAvailable: providerAvailable,
                coverage: coverage
            )
        }
        if !providerAvailable {
            return .keyword
        }
        if (request.mode == .semantic || request.mode == .hybrid),
           request.coveragePolicy == .requireComplete,
           coverage?.isComplete != true {
            return .keyword
        }
        return request.mode
    }

    // MARK: Ветви

    private func runKeyword(
        request: DocumentSearchRequest,
        resolved: UnifiedDocumentSearchMode,
        limit: Int,
        coverage: LocalEmbeddingCoverage?,
        coverageMs: Int?,
        startedAt: Date
    ) async throws -> DocumentSearchExecution {
        let lexicalStartedAt = Date()
        let keyword = try await store.searchChunksKeyword(
            query: request.query,
            scope: request.scope,
            variantFilter: request.variantFilter,
            limit: limit
        )
        let lexicalMs = Self.elapsedMilliseconds(since: lexicalStartedAt)
        return Self.execution(
            request: request,
            resolved: resolved,
            results: keyword.hits,
            diagnostics: diagnostics(
                coverage: coverage,
                coverageMs: coverageMs,
                prepareMs: nil,
                queryMs: nil,
                vectorMs: nil
            ),
            startedAt: startedAt,
            lexicalMs: lexicalMs
        )
    }

    private func runSemantic(
        request: DocumentSearchRequest,
        resolved: UnifiedDocumentSearchMode,
        limit: Int,
        coverage: LocalEmbeddingCoverage?,
        coverageMs: Int?,
        startedAt: Date
    ) async throws -> DocumentSearchExecution {
        let branch = try await semanticBranch(
            request: request,
            limit: limit,
            coverage: coverage,
            coverageMs: coverageMs
        )
        return Self.execution(
            request: request,
            resolved: resolved,
            results: Array(branch.results.prefix(limit)),
            diagnostics: branch.diagnostics,
            startedAt: startedAt,
            fusionMs: branch.hydrateMs
        )
    }

    private func runHybrid(
        request: DocumentSearchRequest,
        limit: Int,
        coverage: LocalEmbeddingCoverage?,
        coverageMs: Int?,
        startedAt: Date
    ) async throws -> DocumentSearchExecution {
        let branchLimit = max(limit, 20)
        let store = self.store
        // Длительность лексической ветви замеряется внутри задачи: снаружи `await`
        // показал бы время ожидания, а не работы, потому что ветви идут параллельно.
        async let lexicalTask: (result: KeywordSearchResult, ms: Int) = {
            let started = Date()
            let result = try await store.searchChunksKeyword(
                query: request.query,
                scope: request.scope,
                variantFilter: request.variantFilter,
                limit: branchLimit
            )
            return (result, Self.elapsedMilliseconds(since: started))
        }()
        async let semanticTask = semanticBranch(
            request: request,
            limit: branchLimit,
            coverage: coverage,
            coverageMs: coverageMs
        )

        let (lexical, lexicalMs) = try await lexicalTask
        let semantic = try await semanticTask

        let fusionStartedAt = Date()
        let merged = ReciprocalRankFusion.merge(
            lexical: lexical.hits,
            semantic: semantic.results,
            limit: limit
        )
        let fusionMs = Self.elapsedMilliseconds(since: fusionStartedAt)
        return Self.execution(
            request: request,
            resolved: .hybrid,
            results: merged,
            diagnostics: semantic.diagnostics,
            startedAt: startedAt,
            lexicalMs: lexicalMs,
            fusionMs: fusionMs
        )
    }

    private struct SemanticBranch: Sendable {
        let results: [ChunkSearchResult]
        let diagnostics: LocalEmbeddingSearchDiagnostics?
        let hydrateMs: Int
    }

    private func semanticBranch(
        request: DocumentSearchRequest,
        limit: Int,
        coverage: LocalEmbeddingCoverage?,
        coverageMs: Int?
    ) async throws -> SemanticBranch {
        guard let embedding else {
            throw DocumentIndexError.invalidArgument("семантический поиск без провайдера эмбеддингов")
        }

        let prepareStartedAt = Date()
        try await embedding.provider.prepare()
        let prepareMs = Self.elapsedMilliseconds(since: prepareStartedAt)

        try await ensureCompatibleModel(embedding.provider)

        let queryStartedAt = Date()
        let queryReport = try await embedding.provider.embeddingReport(
            for: request.query,
            purpose: .query
        )
        let queryVector = queryReport.vector
        let queryMs = Self.elapsedMilliseconds(since: queryStartedAt)

        let vectorStartedAt = Date()
        let candidates = try await loadCandidates(
            scope: request.scope,
            modelId: embedding.descriptor.modelId,
            variantFilter: request.variantFilter
        )
        let matches = VectorScan.topK(
            query: queryVector,
            candidates: candidates,
            dimension: embedding.descriptor.dimension,
            k: max(limit, 1)
        )
        let vectorMs = Self.elapsedMilliseconds(since: vectorStartedAt)

        let hydrateStartedAt = Date()
        let hydrated = try await store.hydrateChunks(
            matches: matches,
            scope: request.scope,
            variantFilter: request.variantFilter
        )
        let hydrateMs = Self.elapsedMilliseconds(since: hydrateStartedAt)

        return SemanticBranch(
            results: hydrated,
            diagnostics: diagnostics(
                coverage: coverage,
                coverageMs: coverageMs,
                prepareMs: prepareMs,
                queryMs: queryMs,
                vectorMs: vectorMs,
                queryInputTruncated: queryReport.truncated
            ),
            hydrateMs: hydrateMs
        )
    }

    /// Точка расширения: сюда позже встанет кеш кандидатов области.
    private func loadCandidates(
        scope: SearchScope,
        modelId: String,
        variantFilter: DocumentTextVariantFilter
    ) async throws -> [EmbeddingCandidate] {
        try await store.embeddingCandidates(
            in: scope,
            modelId: modelId,
            variantFilter: variantFilter
        )
    }

    /// Провайдер должен совпадать с моделью сохранённых векторов.
    /// На пустой базе незарегистрированная модель допустима: кандидатов нет.
    /// Если в индексе уже есть другая модель — не сравниваем чужие векторы.
    private func ensureCompatibleModel(_ provider: any LocalEmbeddingProvider) async throws {
        let descriptor = provider.descriptor
        if let registered = try await store.embeddingModel(id: descriptor.modelId) {
            if registered.dimension != descriptor.dimension || registered.provider != descriptor.providerId {
                throw LocalEmbeddingProviderError.incompatibleModel(
                    expected: "\(registered.provider)/\(registered.modelId) dim=\(registered.dimension)",
                    actual: "\(descriptor.providerId)/\(descriptor.modelId) dim=\(descriptor.dimension)"
                )
            }
            return
        }
        if let storedDefault = try await store.defaultEmbeddingModelId(),
           storedDefault != descriptor.modelId {
            throw LocalEmbeddingProviderError.incompatibleModel(
                expected: storedDefault,
                actual: descriptor.modelId
            )
        }
        let others = try await store.embeddingModels().filter { $0.modelId != descriptor.modelId }
        if !others.isEmpty {
            throw LocalEmbeddingProviderError.incompatibleModel(
                expected: others[0].modelId,
                actual: descriptor.modelId
            )
        }
    }

    private func diagnostics(
        coverage: LocalEmbeddingCoverage?,
        coverageMs: Int?,
        prepareMs: Int?,
        queryMs: Int?,
        vectorMs: Int?,
        queryInputTruncated: Bool = false
    ) -> LocalEmbeddingSearchDiagnostics? {
        guard let embedding, let coverage else { return nil }
        return LocalEmbeddingSearchDiagnostics(
            providerId: embedding.descriptor.providerId,
            modelId: embedding.descriptor.modelId,
            dimension: embedding.descriptor.dimension,
            coverage: coverage,
            coverageCheckDurationMilliseconds: coverageMs,
            modelPreparationDurationMilliseconds: prepareMs,
            queryEmbeddingDurationMilliseconds: queryMs,
            vectorSearchDurationMilliseconds: vectorMs,
            queryInputTruncated: queryInputTruncated
        )
    }

    private static func execution(
        request: DocumentSearchRequest,
        resolved: UnifiedDocumentSearchMode,
        results: [ChunkSearchResult],
        diagnostics: LocalEmbeddingSearchDiagnostics?,
        startedAt: Date,
        lexicalMs: Int? = nil,
        fusionMs: Int? = nil
    ) -> DocumentSearchExecution {
        DocumentSearchExecution(
            requestedMode: request.mode,
            resolvedMode: resolved,
            results: results,
            embeddingDiagnostics: diagnostics,
            searchDurationMilliseconds: elapsedMilliseconds(since: startedAt),
            coverageCheckDurationMilliseconds: diagnostics?.coverageCheckDurationMilliseconds,
            lexicalSearchDurationMilliseconds: lexicalMs,
            fusionPresentationDurationMilliseconds: fusionMs
        )
    }

    private static func elapsedMilliseconds(since start: Date) -> Int {
        max(Int(Date().timeIntervalSince(start) * 1_000), 0)
    }
}
