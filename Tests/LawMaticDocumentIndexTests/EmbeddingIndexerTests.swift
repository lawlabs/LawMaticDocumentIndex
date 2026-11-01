import Foundation
import SQLite
import Testing
@testable import LawMaticDocumentIndex

@Test("indexScope строит полное покрытие и помечает задачи done")
func индексаторПокрываетОбласть() async throws {
    let env = try await IndexerEnv()
    let content = слова(400)
    try await env.attach(documentId: "doc-1", path: "Дело/длинный.docx", text: content)
    let chunkCount = try await env.store.chunks(textHash: DocumentIndexStore.textHash(of: content)).count
    #expect(chunkCount >= 2)

    let provider = FakeEmbeddingProvider()
    let indexer = EmbeddingIndexer(store: env.store, provider: provider, batchSize: 2)
    let summary = try await indexer.indexScope(.everything)

    let coverage = try await env.store.embeddingCoverage(in: .everything, modelId: provider.descriptor.modelId)
    #expect(coverage.isComplete)
    #expect(coverage.totalChunks == chunkCount)
    #expect(summary.embeddedChunks == chunkCount)
    #expect(summary.failedJobs == 0)
    #expect(summary.remainingJobs == 0)
    #expect(try await env.store.jobs(kind: .embed).allSatisfy { $0.state == .done })

    let expectedBatches = (chunkCount + 1) / 2
    #expect(provider.batchCalls == expectedBatches)

    let again = try await indexer.indexScope(.everything)
    #expect(again.processedJobs == 0)
    #expect(again.embeddedChunks == 0)
    #expect(provider.batchCalls == expectedBatches)
}

@Test("Ошибка провайдера возвращает задачу в очередь, после maxAttempts — failed")
func индексаторОшибкаИИсчерпаниеПопыток() async throws {
    let env = try await IndexerEnv()
    try await env.attach(documentId: "doc-1", path: "Дело/иск.docx", text: "Иск о взыскании долга.")
    let provider = FakeEmbeddingProvider()
    let indexer = EmbeddingIndexer(store: env.store, provider: provider, batchSize: 8, maxAttempts: 3)
    try await indexer.registerModel()
    #expect(try await indexer.enqueue(scope: .everything) == 1)

    provider.failNextBatch = true
    let first = try await indexer.runPendingJobs(jobLimit: 1)
    #expect(first.processedJobs == 1)
    #expect(first.failedJobs == 0)
    let queued = try await env.store.jobs(kind: .embed, states: [.queued])
    #expect(queued.count == 1)
    #expect(queued[0].lastError != nil)
    #expect(queued[0].attempts == 1)

    provider.failNextBatch = true
    _ = try await indexer.runPendingJobs(jobLimit: 1)
    let queuedAgain = try await env.store.jobs(kind: .embed, states: [.queued])
    #expect(queuedAgain.count == 1)
    #expect(queuedAgain[0].attempts == 2)

    provider.failNextBatch = true
    let last = try await indexer.runPendingJobs(jobLimit: 1)
    #expect(last.failedJobs == 1)
    let failed = try await env.store.jobs(kind: .embed, states: [.failed])
    #expect(failed.count == 1)
    #expect(failed[0].attempts == 3)
    #expect(failed[0].lastError != nil)
    #expect(try await env.store.jobs(kind: .embed, states: [.queued]).isEmpty)
}

@Test("Отмена посреди работы: следующий runPendingJobs доводит индекс до конца")
func индексаторОтменаИДовод() async throws {
    let env = try await IndexerEnv()
    try await env.attach(documentId: "doc-a", path: "Дело/a.docx", text: "Первый уникальный текст про поставку.")
    try await env.attach(documentId: "doc-b", path: "Дело/b.docx", text: "Второй уникальный текст про аренду.")
    let provider = FakeEmbeddingProvider()
    let indexer = EmbeddingIndexer(store: env.store, provider: provider, batchSize: 8)
    try await indexer.registerModel()
    #expect(try await indexer.enqueue(scope: .everything) == 2)

    final class Box: @unchecked Sendable {
        var task: Task<EmbeddingIndexerSummary, Error>?
    }
    let box = Box()
    let task = Task {
        try await indexer.runPendingJobs { progress in
            if progress.processedJobs >= 1 {
                box.task?.cancel()
            }
        }
    }
    box.task = task
    _ = try? await task.value

    let coverageAfterCancel = try await env.store.embeddingCoverage(
        in: .everything,
        modelId: provider.descriptor.modelId
    )
    #expect(!coverageAfterCancel.isComplete)

    let summary = try await indexer.runPendingJobs()
    let coverage = try await env.store.embeddingCoverage(
        in: .everything,
        modelId: provider.descriptor.modelId
    )
    #expect(coverage.isComplete)
    #expect(summary.remainingJobs == 0)
    #expect(try await env.store.jobs(kind: .embed, states: [.queued, .running]).isEmpty)
}

@Test("chunksWithoutEmbeddings(textHash:) не возвращает уже покрытые чанки")
func чанкиТекстаБезЭмбеддингаПропускаютПокрытые() async throws {
    let env = try await IndexerEnv()
    let content = слова(400)
    try await env.attach(documentId: "doc-1", path: "Дело/длинный.docx", text: content)
    let hash = DocumentIndexStore.textHash(of: content)
    let all = try await env.store.chunks(textHash: hash)
    #expect(all.count >= 2)

    let provider = FakeEmbeddingProvider()
    try await env.store.registerEmbeddingModel(provider.descriptor)

    let before = try await env.store.chunksWithoutEmbeddings(textHash: hash, modelId: provider.descriptor.modelId)
    #expect(before.map(\.rowid) == all.map(\.rowid))

    try await env.store.storeChunkEmbeddings(
        [ChunkEmbeddingBatchItem(
            chunkRowid: all[0].rowid,
            embedding: VectorQuantizer.quantize(
                FakeEmbeddingProvider.vector(for: "x", dimension: 32)
            )
        )],
        modelId: provider.descriptor.modelId
    )
    let after = try await env.store.chunksWithoutEmbeddings(textHash: hash, modelId: provider.descriptor.modelId)
    #expect(after.map(\.rowid) == Array(all.dropFirst().map(\.rowid)))
}

// MARK: - Фикстуры

private final class IndexerEnv {
    let temp = TemporaryDatabase()
    let store: DocumentIndexStore

    init() async throws {
        store = try await temp.openWriter()
        let db = try temp.rawConnection(readonly: false)
        try db.execute("PRAGMA foreign_keys = ON")
        try RawFixtures.insertWorkspaceRoot(db, id: "root-1")
    }

    func attach(documentId: String, path: String, text: String) async throws {
        let db = try temp.rawConnection(readonly: false)
        try db.execute("PRAGMA foreign_keys = ON")
        try RawFixtures.insertWorkspaceDocument(
            db, id: documentId, workspaceRootId: "root-1", relativePath: path
        )
        let stored = try await store.storeText(text)
        _ = try await store.setTextVariant(documentId: documentId, type: .original, textHash: stored.textHash)
    }
}

private func слова(_ count: Int, prefix: String = "слово") -> String {
    (1...count).map { "\(prefix)\($0)" }.joined(separator: " ")
}

@Test("Chunk budget is exact and scoped indexing leaves other queued cases untouched")
func boundedScopedIndexing() async throws {
    let env = try await IndexerEnv()
    try await env.attach(documentId: "selected", path: "Дело/a.txt", text: слова(900))
    try await env.attach(documentId: "other", path: "Другое/b.txt", text: слова(500, prefix: "иной"))
    let provider = FakeEmbeddingProvider()
    let indexer = EmbeddingIndexer(store: env.store, provider: provider)
    try await indexer.registerModel()
    _ = try await indexer.enqueue(scope: .everything)
    let scope = SearchScope.documents(ids: ["selected"])
    let first = try await indexer.runPendingJobs(maximumChunks: 1, scope: scope)
    #expect(first.embeddedChunks == 1)
    let partial = try await env.store.embeddingCoverage(in: scope, modelId: provider.descriptor.modelId)
    #expect(!partial.isComplete)
    #expect(try await env.store.embeddingCoverage(in: .documents(ids: ["other"]), modelId: provider.descriptor.modelId).embeddedChunks == 0)
    _ = try await indexer.runPendingJobs(scope: scope)
    #expect(try await env.store.embeddingCoverage(in: scope, modelId: provider.descriptor.modelId).isComplete)
    #expect(try await env.store.embeddingCoverage(in: .documents(ids: ["other"]), modelId: provider.descriptor.modelId).embeddedChunks == 0)
}
