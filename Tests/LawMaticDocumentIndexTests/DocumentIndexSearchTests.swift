import Foundation
import SQLite
import Testing
@testable import LawMaticDocumentIndex

@Test("Keyword без провайдера отдаёт лексические хиты")
func поискKeywordБезПровайдера() async throws {
    let env = try await SearchFacadeEnv()
    try await env.attach(
        documentId: "doc-1", path: "Дело/иск.docx",
        text: "Иск о взыскании неосновательного обогащения удовлетворён."
    )
    let search = DocumentIndexSearch(store: env.store)
    let execution = try await search.search(
        DocumentIndexSearch.DocumentSearchRequest(
            query: "взыскание неосновательного обогащения",
            scope: .workspaceRoot(id: "root-1"),
            mode: .keyword
        )
    )
    #expect(execution.requestedMode == .keyword)
    #expect(execution.resolvedMode == .keyword)
    #expect(execution.results.map(\.documentId) == ["doc-1"])
    #expect(execution.results[0].source == .lexical)
    #expect(execution.embeddingDiagnostics == nil)
}

@Test("Auto без провайдера резолвится в keyword")
func поискAutoБезПровайдера() async throws {
    let env = try await SearchFacadeEnv()
    try await env.attach(
        documentId: "doc-1", path: "Дело/иск.docx",
        text: "Иск о взыскании долга."
    )
    let search = DocumentIndexSearch(store: env.store)
    let execution = try await search.search(
        DocumentIndexSearch.DocumentSearchRequest(
            query: "взыскание долга",
            scope: .everything,
            mode: .auto
        )
    )
    #expect(execution.resolvedMode == .keyword)
    #expect(execution.results[0].source == .lexical)
}

@Test("Auto с провайдером и неполным покрытием — keyword")
func поискAutoПриНеполномПокрытии() async throws {
    let env = try await SearchFacadeEnv()
    try await env.attach(
        documentId: "doc-1", path: "Дело/иск.docx",
        text: "Иск о взыскании долга."
    )
    let provider = FakeEmbeddingProvider()
    try await env.store.registerEmbeddingModel(provider.descriptor)
    let search = DocumentIndexSearch(
        store: env.store,
        embedding: .init(provider: provider)
    )
    let execution = try await search.search(
        DocumentIndexSearch.DocumentSearchRequest(
            query: "взыскание долга",
            scope: .everything,
            mode: .auto
        )
    )
    #expect(execution.resolvedMode == .keyword)
    #expect(provider.prepareCalls == 0)
    #expect(provider.embeddingCalls == 0)
}

@Test("Auto с полным покрытием — hybrid")
func поискAutoПриПолномПокрытии() async throws {
    let env = try await SearchFacadeEnv()
    try await env.attach(
        documentId: "doc-1", path: "Дело/иск.docx",
        text: "Иск о взыскании долга по договору поставки."
    )
    let provider = FakeEmbeddingProvider()
    try await env.indexAll(provider: provider)
    let search = DocumentIndexSearch(
        store: env.store,
        embedding: .init(provider: provider)
    )
    let execution = try await search.search(
        DocumentIndexSearch.DocumentSearchRequest(
            query: "взыскание долга",
            scope: .everything,
            mode: .auto
        )
    )
    #expect(execution.resolvedMode == .hybrid)
    #expect(!execution.results.isEmpty)
    #expect(execution.results.allSatisfy { $0.source == .hybrid })
}

@Test("Явный semantic при requireComplete и неполном покрытии — keyword")
func поискSemanticRequireCompleteПриНеполномПокрытии() async throws {
    let env = try await SearchFacadeEnv()
    try await env.attach(
        documentId: "doc-1", path: "Дело/иск.docx",
        text: "Иск о взыскании долга."
    )
    let provider = FakeEmbeddingProvider()
    try await env.store.registerEmbeddingModel(provider.descriptor)
    let search = DocumentIndexSearch(
        store: env.store,
        embedding: .init(provider: provider)
    )
    let execution = try await search.search(
        DocumentIndexSearch.DocumentSearchRequest(
            query: "взыскание долга",
            scope: .everything,
            mode: .semantic,
            coveragePolicy: .requireComplete
        )
    )
    #expect(execution.resolvedMode == .keyword)
    #expect(execution.results[0].source == .lexical)
    #expect(provider.prepareCalls == 0)
}

@Test("Явный semantic при allowPartial гидратирует результаты и заполняет диагностику")
func поискSemanticAllowPartial() async throws {
    let env = try await SearchFacadeEnv()
    try await env.attach(
        documentId: "doc-1", path: "Дело/иск.docx",
        text: "Иск о взыскании долга по договору."
    )
    try await env.attach(
        documentId: "doc-2", path: "Дело/акт.docx",
        text: "Акт сверки взаимных расчётов сторон."
    )
    let provider = FakeEmbeddingProvider()
    try await env.indexDocument(id: "doc-1", text: "Иск о взыскании долга по договору.", provider: provider)

    let search = DocumentIndexSearch(
        store: env.store,
        embedding: .init(provider: provider)
    )
    let execution = try await search.search(
        DocumentIndexSearch.DocumentSearchRequest(
            query: "взыскание долга",
            scope: .everything,
            mode: .semantic,
            coveragePolicy: .allowPartial
        )
    )
    #expect(execution.resolvedMode == .semantic)
    #expect(execution.results.contains { $0.documentId == "doc-1" })
    #expect(execution.results.allSatisfy { $0.source == .semantic })
    #expect(!execution.results[0].content.isEmpty)
    let diagnostics = try #require(execution.embeddingDiagnostics)
    #expect(diagnostics.dimension == 32)
    #expect(diagnostics.coverage.embeddedChunks == 1)
    #expect(diagnostics.coverage.totalChunks == 2)
    #expect(diagnostics.coverageCheckDurationMilliseconds != nil)
    #expect(diagnostics.modelPreparationDurationMilliseconds != nil)
    #expect(diagnostics.queryEmbeddingDurationMilliseconds != nil)
    #expect(diagnostics.vectorSearchDurationMilliseconds != nil)
}

@Test("Hybrid: документ обеих ветвей выше найденного одной")
func поискHybridRRFПоднимаетОбщийДокумент() async throws {
    let env = try await SearchFacadeEnv()
    try await env.attach(
        documentId: "doc-both", path: "Дело/общий.docx",
        text: "Иск о взыскании долга по договору поставки."
    )
    try await env.attach(
        documentId: "doc-lex", path: "Дело/лексический.docx",
        text: "Иск о взыскании долга без поставки оборудования."
    )
    let provider = FakeEmbeddingProvider()
    try await env.indexDocument(
        id: "doc-both",
        text: "Иск о взыскании долга по договору поставки.",
        provider: provider
    )

    let search = DocumentIndexSearch(
        store: env.store,
        embedding: .init(provider: provider)
    )
    let execution = try await search.search(
        DocumentIndexSearch.DocumentSearchRequest(
            query: "взыскание долга",
            scope: .everything,
            mode: .hybrid,
            coveragePolicy: .allowPartial
        )
    )
    #expect(execution.resolvedMode == .hybrid)
    #expect(execution.results.first?.documentId == "doc-both")
    #expect(execution.results.contains { $0.documentId == "doc-lex" })
    #expect(execution.results.allSatisfy { $0.source == .hybrid })
}

@Test("Пустой запрос не вызывает провайдер и не ходит в SQL поиска")
func поискПустогоЗапроса() async throws {
    let env = try await SearchFacadeEnv()
    try await env.attach(
        documentId: "doc-1", path: "Дело/иск.docx",
        text: "Иск о взыскании долга."
    )
    let provider = FakeEmbeddingProvider()
    try await env.indexAll(provider: provider)
    let search = DocumentIndexSearch(
        store: env.store,
        embedding: .init(provider: provider)
    )
    let prepareBefore = provider.prepareCalls
    let embeddingBefore = provider.embeddingCalls

    let execution = try await search.search(
        DocumentIndexSearch.DocumentSearchRequest(
            query: "   \n",
            scope: .everything,
            mode: .semantic
        )
    )
    #expect(execution.results.isEmpty)
    #expect(provider.prepareCalls == prepareBefore)
    #expect(provider.embeddingCalls == embeddingBefore)
}

@Test("Ошибка провайдера при auto даёт keyword, при явном semantic — throws")
func поискОшибкаПровайдераAutoИЯвныйSemantic() async throws {
    let env = try await SearchFacadeEnv()
    try await env.attach(
        documentId: "doc-1", path: "Дело/иск.docx",
        text: "Иск о взыскании долга по договору."
    )
    let provider = FakeEmbeddingProvider()
    try await env.indexAll(provider: provider)
    let search = DocumentIndexSearch(
        store: env.store,
        embedding: .init(provider: provider)
    )

    provider.failNextEmbedding = true
    let auto = try await search.search(
        DocumentIndexSearch.DocumentSearchRequest(
            query: "взыскание долга",
            scope: .everything,
            mode: .auto
        )
    )
    #expect(auto.resolvedMode == .keyword)
    #expect(auto.results.map(\.documentId) == ["doc-1"])
    #expect(auto.results[0].source == .lexical)

    provider.failNextEmbedding = true
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
}

@Test("context фасада совпадает со store.chunkContext")
func поискКонтекстЧерезФасад() async throws {
    let env = try await SearchFacadeEnv()
    let content = (1...480).map { "слово\($0)" }.joined(separator: " ")
    try await env.attach(documentId: "doc-long", path: "Дело/длинный.docx", text: content)
    let chunks = try await env.store.chunks(textHash: DocumentIndexStore.textHash(of: content))
    let search = DocumentIndexSearch(store: env.store)
    let viaFacade = try await search.context(
        chunkId: chunks[1].id,
        documentId: "doc-long",
        surroundingChunks: 1
    )
    let viaStore = try await env.store.chunkContext(
        chunkId: chunks[1].id,
        documentId: "doc-long",
        surroundingChunks: 1
    )
    #expect(viaFacade.map(\.chunkId) == viaStore.map(\.chunkId))
}

// MARK: - Фикстуры

private final class SearchFacadeEnv {
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

    func indexAll(provider: FakeEmbeddingProvider) async throws {
        try await store.registerEmbeddingModel(provider.descriptor)
        let missing = try await store.chunksWithoutEmbeddings(
            in: .everything,
            modelId: provider.descriptor.modelId,
            limit: 256
        )
        try await storeEmbeddings(missing, provider: provider)
    }

    func indexDocument(id: String, text: String, provider: FakeEmbeddingProvider) async throws {
        try await store.registerEmbeddingModel(provider.descriptor)
        let hash = DocumentIndexStore.textHash(of: text)
        let missing = try await store.chunksWithoutEmbeddings(
            textHash: hash,
            modelId: provider.descriptor.modelId
        )
        try await storeEmbeddings(missing, provider: provider)
    }

    private func storeEmbeddings(
        _ missing: [(rowid: Int64, item: ChunkEmbeddingWorkItem)],
        provider: FakeEmbeddingProvider
    ) async throws {
        let items = missing.map { pair in
            ChunkEmbeddingBatchItem(
                chunkRowid: pair.rowid,
                embedding: VectorQuantizer.quantize(
                    FakeEmbeddingProvider.vector(for: pair.item.content, dimension: provider.descriptor.dimension)
                )
            )
        }
        try await store.storeChunkEmbeddings(items, modelId: provider.descriptor.modelId)
    }
}
