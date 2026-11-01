import Foundation
import SQLite
import Testing
@testable import LawMaticDocumentIndex

@Test("После замены original очередь embed не ставит устаревший text_hash")
func очередьНеСтавитУстаревшийТекст() async throws {
    let env = try await HonestyEnv()
    let oldText = "Старый текст договора поставки."
    let newText = "Новый текст акта сверки взаимных расчётов."
    try await env.attach(documentId: "doc-1", path: "Дело/договор.txt", text: oldText)
    let oldHash = DocumentIndexStore.textHash(of: oldText)
    let newHash = DocumentIndexStore.textHash(of: newText)

    let provider = FakeEmbeddingProvider()
    try await env.store.registerEmbeddingModel(provider.descriptor)
    try await env.store.setDefaultEmbeddingModelId(provider.descriptor.modelId)
    #expect(try await env.store.enqueueEmbedJobs(in: .everything, modelId: provider.descriptor.modelId) == 1)
    #expect(
        try await env.store.jobs(kind: .embed).map(\.target)
            == [IndexJobRecord.textTarget(oldHash)]
    )

    try await env.store.storeExtraction(
        documentId: "doc-1",
        content: newText,
        state: .init(documentId: "doc-1", status: .complete),
        sourceFileHash: nil
    )
    let jobs = try await env.store.jobs(kind: .embed, states: [.queued])
    #expect(jobs.map(\.target).contains(IndexJobRecord.textTarget(newHash)))
    #expect(!jobs.map(\.target).contains(IndexJobRecord.textTarget(oldHash)))
}

@Test("Удалённый документ не получает новых embed-задач")
func удалённыйДокументНеСтавитсяВОчередьЭмбеддингов() async throws {
    let env = try await HonestyEnv()
    try await env.attach(documentId: "doc-1", path: "Дело/иск.txt", text: "Иск о взыскании долга.")
    let provider = FakeEmbeddingProvider()
    try await env.store.registerEmbeddingModel(provider.descriptor)
    #expect(try await env.store.removeDocuments(in: .documents(ids: ["doc-1"])) == 1)
    #expect(try await env.store.enqueueEmbedJobs(in: .everything, modelId: provider.descriptor.modelId) == 0)
}

@Test("100% векторов извлечённых чанков не означает полную обработку дела")
func покрытиеВекторовНеРавноПолнойОбработке() async throws {
    let env = try await HonestyEnv()
    try await env.attach(documentId: "extracted", path: "Дело/акт.txt", text: "Акт сверки сторон.")
    try RawFixtures.insertWorkspaceDocument(
        try env.temp.rawConnection(readonly: false),
        id: "partial-pdf",
        workspaceRootId: "root-1",
        relativePath: "Дело/скан.pdf"
    )
    try await env.store.storeExtraction(
        documentId: "partial-pdf",
        content: "Только первая страница.",
        state: .init(
            documentId: "partial-pdf",
            status: .partial,
            pagesTotal: 4,
            pagesProcessed: 1
        ),
        sourceFileHash: nil
    )

    let provider = FakeEmbeddingProvider()
    let indexer = EmbeddingIndexer(store: env.store, provider: provider)
    _ = try await indexer.indexScope(.everything)

    let coverage = try await env.store.processingCoverage(
        in: .everything,
        modelId: provider.descriptor.modelId
    )
    #expect(coverage.embedding.isComplete)
    #expect(coverage.partialExtractions == 1)
    #expect(coverage.completeExtractions == 1)
    #expect(!coverage.isFullyProcessed)
    #expect(coverage.extractionSettled == false)
}

@Test("Явный semantic с чужим model ID не сравнивает векторы и бросает ошибку")
func несовместимыйModelIdНеСравниваетВекторы() async throws {
    let env = try await HonestyEnv()
    try await env.attach(documentId: "doc-1", path: "Дело/иск.txt", text: "Иск о взыскании долга.")
    let indexed = FakeEmbeddingProvider(modelId: "vec-a")
    try await env.store.registerEmbeddingModel(indexed.descriptor)
    let indexer = EmbeddingIndexer(store: env.store, provider: indexed)
    _ = try await indexer.indexScope(.everything)

    let foreign = FakeEmbeddingProvider(modelId: "vec-b")
    let search = DocumentIndexSearch(store: env.store, embedding: .init(provider: foreign))
    await #expect(throws: LocalEmbeddingProviderError.self) {
        _ = try await search.search(
            DocumentIndexSearch.DocumentSearchRequest(
                query: "взыскание долга",
                scope: .everything,
                mode: .semantic,
                coveragePolicy: .allowPartial
            )
        )
    }

    let auto = try await search.search(
        DocumentIndexSearch.DocumentSearchRequest(
            query: "взыскание долга",
            scope: .everything,
            mode: .auto
        )
    )
    #expect(auto.resolvedMode == .keyword)
    #expect(auto.results.map(\.documentId) == ["doc-1"])
}

@Test("default_embedding_model_id читается из metadata после выбора модели")
func идентификаторМоделиПоУмолчаниюИзБазы() async throws {
    let env = try await HonestyEnv()
    #expect(try await env.store.defaultEmbeddingModelId() == nil)
    try await env.store.setDefaultEmbeddingModelId("apple.nlcontextual.test.v1")
    #expect(try await env.store.defaultEmbeddingModelId() == "apple.nlcontextual.test.v1")
}

private final class HonestyEnv {
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
        try await store.storeExtraction(
            documentId: documentId,
            content: text,
            state: .init(documentId: documentId, status: .complete),
            sourceFileHash: nil
        )
    }
}
