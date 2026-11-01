import Foundation

public struct EmbeddingIndexerProgress: Sendable {
    public let processedJobs: Int
    public let failedJobs: Int
    public let embeddedChunks: Int
    public let remainingJobs: Int

    public init(processedJobs: Int, failedJobs: Int, embeddedChunks: Int, remainingJobs: Int) {
        self.processedJobs = processedJobs
        self.failedJobs = failedJobs
        self.embeddedChunks = embeddedChunks
        self.remainingJobs = remainingJobs
    }
}

public struct EmbeddingIndexerSummary: Sendable {
    public let processedJobs: Int
    public let failedJobs: Int
    public let embeddedChunks: Int
    public let remainingJobs: Int
    public let durationMilliseconds: Int

    public init(
        processedJobs: Int,
        failedJobs: Int,
        embeddedChunks: Int,
        remainingJobs: Int,
        durationMilliseconds: Int
    ) {
        self.processedJobs = processedJobs
        self.failedJobs = failedJobs
        self.embeddedChunks = embeddedChunks
        self.remainingJobs = remainingJobs
        self.durationMilliseconds = durationMilliseconds
    }
}

/// Строит эмбеддинги по очереди `index_jobs` (kind = embed, цель `text:<hash>`).
public actor EmbeddingIndexer {
    private let store: DocumentIndexStore
    private let provider: any LocalEmbeddingProvider
    private let batchSize: Int
    private let maxAttempts: Int

    public init(
        store: DocumentIndexStore,
        provider: any LocalEmbeddingProvider,
        batchSize: Int = 32,
        maxAttempts: Int = 3
    ) {
        self.store = store
        self.provider = provider
        self.batchSize = max(batchSize, 1)
        self.maxAttempts = max(maxAttempts, 1)
    }

    @discardableResult
    public func registerModel() async throws -> EmbeddingModelRecord {
        try await store.registerEmbeddingModel(provider.descriptor)
    }

    @discardableResult
    public func enqueue(scope: SearchScope, priority: Int = 0) async throws -> Int {
        try await store.enqueueEmbedJobs(
            in: scope,
            modelId: provider.descriptor.modelId,
            priority: priority
        )
    }

    public func runPendingJobs(
        jobLimit: Int? = nil,
        maximumChunks: Int? = nil,
        scope: SearchScope = .everything,
        progress: (@Sendable (EmbeddingIndexerProgress) -> Void)? = nil
    ) async throws -> EmbeddingIndexerSummary {
        let startedAt = Date()
        // Следующий запуск сам подберёт зависшие running через resetRunningJobs:
        // при отмене не возвращаем их в queued сами, чтобы не гоняться с другим писателем
        // и не терять attempts у уже начатой попытки.
        _ = try await store.resetRunningJobs()
        try await provider.prepare()

        var processedJobs = 0
        var failedJobs = 0
        var embeddedChunks = 0
        var lastRemaining = 0
        let modelId = provider.descriptor.modelId
        let dimension = provider.descriptor.dimension

        // По одной задаче: так отмена между задачами не оставляет пачку running.
        loop: while true {
            if Task.isCancelled { break }
            if let jobLimit, processedJobs >= jobLimit { break }
            if let maximumChunks, embeddedChunks >= max(maximumChunks, 0) { break }

            let jobs = try await store.claimNextJobs(
                kind: .embed,
                limit: 1,
                modelId: modelId,
                scope: scope
            )
            guard let job = jobs.first else { break }

            do {
                let result = try await embed(job: job, modelId: modelId, dimension: dimension,
                    maximumChunks: maximumChunks.map { max($0 - embeddedChunks, 0) })
                if result.complete { try await store.completeJob(id: job.id) }
                else { try await store.releaseJob(id: job.id) }
                processedJobs += 1
                embeddedChunks += result.count
            } catch is CancellationError {
                break loop
            } catch {
                let requeue = job.attempts < maxAttempts
                try await store.failJob(
                    id: job.id,
                    error: (error as? LocalizedError)?.errorDescription ?? String(describing: error),
                    requeue: requeue
                )
                processedJobs += 1
                if !requeue { failedJobs += 1 }
            }

            lastRemaining = (try? await remainingEmbedJobs()) ?? lastRemaining
            progress?(
                EmbeddingIndexerProgress(
                    processedJobs: processedJobs,
                    failedJobs: failedJobs,
                    embeddedChunks: embeddedChunks,
                    remainingJobs: lastRemaining
                )
            )
            if Task.isCancelled { break }
        }

        let remaining = Task.isCancelled
            ? lastRemaining
            : ((try? await remainingEmbedJobs()) ?? lastRemaining)
        return EmbeddingIndexerSummary(
            processedJobs: processedJobs,
            failedJobs: failedJobs,
            embeddedChunks: embeddedChunks,
            remainingJobs: remaining,
            durationMilliseconds: max(Int(Date().timeIntervalSince(startedAt) * 1_000), 0)
        )
    }

    public func indexScope(
        _ scope: SearchScope,
        progress: (@Sendable (EmbeddingIndexerProgress) -> Void)? = nil
    ) async throws -> EmbeddingIndexerSummary {
        try await registerModel()
        _ = try await enqueue(scope: scope)
        return try await runPendingJobs(scope: scope, progress: progress)
    }

    // MARK: Одна задача

    private func embed(job: IndexJobRecord, modelId: String, dimension: Int,
                       maximumChunks: Int?) async throws -> (count: Int, complete: Bool) {
        guard let textHash = IndexJobRecord.textHash(fromTarget: job.target) else {
            throw DocumentIndexError.invalidArgument("некорректная цель embed-задачи: \(job.target)")
        }
        let pending = try await store.chunksWithoutEmbeddings(textHash: textHash, modelId: modelId)
        if pending.isEmpty { return (0, true) }
        let limit = min(pending.count, maximumChunks ?? pending.count)

        var embedded = 0
        var index = 0
        while index < limit {
            try Task.checkCancellation()
            let end = min(index + batchSize, limit)
            let batch = Array(pending[index..<end])
            let vectors = try await provider.embeddings(
                for: batch.map(\.item.content),
                purpose: .document
            )
            guard vectors.count == batch.count else {
                throw LocalEmbeddingProviderError.inconsistentDimension(
                    expected: batch.count,
                    actual: vectors.count
                )
            }
            var items: [ChunkEmbeddingBatchItem] = []
            items.reserveCapacity(batch.count)
            for (pair, vector) in zip(batch, vectors) {
                guard vector.count == dimension else {
                    throw LocalEmbeddingProviderError.inconsistentDimension(
                        expected: dimension,
                        actual: vector.count
                    )
                }
                items.append(
                    ChunkEmbeddingBatchItem(
                        chunkRowid: pair.rowid,
                        embedding: VectorQuantizer.quantize(vector)
                    )
                )
            }
            try await store.storeChunkEmbeddings(items, modelId: modelId)
            embedded += items.count
            index = end
        }
        return (embedded, index == pending.count)
    }

    private func remainingEmbedJobs() async throws -> Int {
        let counts = try await store.jobCounts(kind: .embed)
        return (counts[.queued] ?? 0) + (counts[.running] ?? 0)
    }
}
