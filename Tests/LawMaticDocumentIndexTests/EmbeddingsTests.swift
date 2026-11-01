import Foundation
import SQLite
import Testing
@testable import LawMaticDocumentIndex

@Test("Регистрация модели — upsert по model_id, created_at не сбрасывается")
func регистрацияМоделиUpsert() async throws {
    let temp = TemporaryDatabase()
    let store = try await temp.openWriter()
    let first = LocalEmbeddingDescriptor(providerId: "apple", modelId: "m1", dimension: 4, maximumInputTokens: 64)
    let created = try await store.registerEmbeddingModel(first)
    #expect(created.provider == "apple")
    #expect(created.dimension == 4)
    #expect(created.quantization == "int8")

    let updated = try await store.registerEmbeddingModel(first)
    #expect(updated.createdAt == created.createdAt)
    await #expect(throws: DocumentIndexError.self) {
        _ = try await store.registerEmbeddingModel(LocalEmbeddingDescriptor(
            providerId: "mlx", modelId: "m1", dimension: 8, maximumInputTokens: 64))
    }
    #expect(try await store.embeddingModels().count == 1)
    #expect(try await store.embeddingModel(id: "m1")?.dimension == 4)

}

@Test("storeChunkEmbeddings пишет батч в одной транзакции, отвергает размерность и заменяет вектор")
func записьЭмбеддинговБатчом() async throws {
    let (temp, store, db) = try await открытьСкладСФикстурой()
    let rowids = try RawFixtures.insertText(db, hash: "h-batch", content: "договор поставки товара")
    try RawFixtures.insertVariant(db, documentId: "doc-a", textHash: "h-batch")
    #expect(rowids.count == 1)

    let descriptor = LocalEmbeddingDescriptor(providerId: "test", modelId: "vec-4", dimension: 4, maximumInputTokens: 32)
    try await store.registerEmbeddingModel(descriptor)

    let first = VectorQuantizer.quantize([1, 0, 0, 0])
    let second = VectorQuantizer.quantize([0, 1, 0, 0])
    try await store.storeChunkEmbeddings(
        [ChunkEmbeddingBatchItem(chunkRowid: rowids[0], embedding: first)],
        modelId: "vec-4"
    )
    #expect(try await store.embeddingCount(modelId: "vec-4") == 1)

    await #expect(throws: DocumentIndexError.self) {
        try await store.storeChunkEmbeddings(
            [ChunkEmbeddingBatchItem(chunkRowid: rowids[0], embedding: VectorQuantizer.quantize([1, 0]))],
            modelId: "vec-4"
        )
    }
    #expect(try await store.embeddingCount(modelId: "vec-4") == 1)

    try await store.storeChunkEmbeddings(
        [ChunkEmbeddingBatchItem(chunkRowid: rowids[0], embedding: second)],
        modelId: "vec-4"
    )
    let candidates = try await store.embeddingCandidates(in: .everything, modelId: "vec-4")
    #expect(candidates.count == 1)
    #expect(abs(candidates[0].scale - second.scale) < 1e-6)
    #expect(candidates[0].vector == second.bytes)

    let count = try db.scalar("SELECT COUNT(*) FROM chunk_embeddings WHERE model_id = 'vec-4'") as? Int64
    #expect(count == 1)
    _ = temp
}

@Test("Покрытие: 0/N → частичное → полное; копия текста не удваивает чанки; фильтр варианта")
func покрытиеОбластиИКопииТекста() async throws {
    let (temp, store, db) = try await открытьСкладСФикстурой()
    let longText = слова(480)
    let sharedRowids = try RawFixtures.insertText(db, hash: "h-shared", content: longText)
    #expect(sharedRowids.count == 3)
    try RawFixtures.insertWorkspaceDocument(
        db, id: "doc-copy", workspaceRootId: "ws", relativePath: "ДелоА/копия.docx", caseId: "case-a"
    )
    try RawFixtures.insertVariant(db, documentId: "doc-a", textHash: "h-shared")
    try RawFixtures.insertVariant(db, documentId: "doc-copy", textHash: "h-shared")

    let anonText = "обезличенный договор поставки"
    let anonRowids = try RawFixtures.insertText(db, hash: "h-anon", content: anonText)
    try RawFixtures.insertVariant(db, documentId: "doc-a", textHash: "h-anon", type: "anonymized")

    try RawFixtures.insertWorkspaceDocument(
        db, id: "doc-b", workspaceRootId: "ws", relativePath: "ДелоБ/b.docx", caseId: "case-b"
    )
    let otherRowids = try RawFixtures.insertText(db, hash: "h-b", content: "иск о взыскании долга")
    try RawFixtures.insertVariant(db, documentId: "doc-b", textHash: "h-b")

    try await store.registerEmbeddingModel(
        LocalEmbeddingDescriptor(providerId: "test", modelId: "vec-4", dimension: 4, maximumInputTokens: 32)
    )

    let empty = try await store.embeddingCoverage(in: .wholeCase(id: "case-a"), modelId: "vec-4")
    #expect(empty.totalChunks == sharedRowids.count)
    #expect(empty.embeddedChunks == 0)

    try await store.storeChunkEmbeddings(
        [ChunkEmbeddingBatchItem(chunkRowid: sharedRowids[0], embedding: VectorQuantizer.quantize([1, 0, 0, 0]))],
        modelId: "vec-4"
    )
    let partial = try await store.embeddingCoverage(in: .wholeCase(id: "case-a"), modelId: "vec-4")
    #expect(partial.embeddedChunks == 1)
    #expect(partial.totalChunks == 3)

    try await store.storeChunkEmbeddings(
        sharedRowids.dropFirst().map {
            ChunkEmbeddingBatchItem(chunkRowid: $0, embedding: VectorQuantizer.quantize([0, 1, 0, 0]))
        },
        modelId: "vec-4"
    )
    let full = try await store.embeddingCoverage(in: .wholeCase(id: "case-a"), modelId: "vec-4")
    #expect(full.isComplete)
    #expect(full.totalChunks == 3)

    let everythingOriginal = try await store.embeddingCoverage(in: .everything, modelId: "vec-4")
    #expect(everythingOriginal.totalChunks == sharedRowids.count + otherRowids.count)

    let folderA = try await store.embeddingCoverage(
        in: .folderPath(workspaceRootId: "ws", relativePath: "ДелоА", recursive: true),
        modelId: "vec-4"
    )
    #expect(folderA.totalChunks == 3)
    let caseB = try await store.embeddingCoverage(in: .wholeCase(id: "case-b"), modelId: "vec-4")
    #expect(caseB.totalChunks == otherRowids.count)
    #expect(caseB.embeddedChunks == 0)

    let originalOnly = try await store.embeddingCoverage(
        in: .documents(ids: ["doc-a"]), modelId: "vec-4", variantFilter: .original
    )
    #expect(originalOnly.totalChunks == 3)
    let anonOnly = try await store.embeddingCoverage(
        in: .documents(ids: ["doc-a"]), modelId: "vec-4", variantFilter: .anonymized
    )
    #expect(anonOnly.totalChunks == anonRowids.count)
    let allVariants = try await store.embeddingCoverage(
        in: .documents(ids: ["doc-a"]), modelId: "vec-4", variantFilter: .all
    )
    #expect(allVariants.totalChunks == sharedRowids.count + anonRowids.count)
    _ = temp
}

@Test("План покрытия рекурсивной папки без SCAN d и SCAN documents")
func планПокрытияРекурсивнойПапкиБезПолногоСкана() async throws {
    let (temp, store, db) = try await открытьСкладСФикстурой()
    try RawFixtures.insertText(db, hash: "h-plan", content: "договор")
    try RawFixtures.insertVariant(db, documentId: "doc-a", textHash: "h-plan")
    try await store.registerEmbeddingModel(
        LocalEmbeddingDescriptor(providerId: "test", modelId: "vec-4", dimension: 4, maximumInputTokens: 32)
    )

    let query = EmbeddingScopeSQL.coverage(
        scope: .folderPath(workspaceRootId: "ws", relativePath: "ДелоА", recursive: true),
        modelId: "vec-4",
        variantFilter: .original
    )
    let plan = try queryPlan(db, query.sql, query.bindings)
    let fullScan = plan.contains { $0 == "SCAN d" || $0.hasPrefix("SCAN d ") || $0.hasPrefix("SCAN documents") }
    #expect(!fullScan, "план без полного просмотра documents: \(plan)")
    _ = store
    _ = temp
}

@Test("chunksWithoutEmbeddings — только непроиндексированные, текст как у SearchChunker, лимит")
func чанкиБезЭмбеддинговСовпадаютСЧанкером() async throws {
    let (temp, store, db) = try await открытьСкладСФикстурой()
    let content = слова(400)
    let drafts = SearchChunker.chunks(from: content)
    let rowids = try RawFixtures.insertText(db, hash: "h-chunk", content: content)
    try RawFixtures.insertVariant(db, documentId: "doc-a", textHash: "h-chunk")
    #expect(rowids.count == drafts.count)
    #expect(drafts.count >= 2)

    try await store.registerEmbeddingModel(
        LocalEmbeddingDescriptor(providerId: "test", modelId: "vec-4", dimension: 4, maximumInputTokens: 32)
    )

    let all = try await store.chunksWithoutEmbeddings(in: .wholeCase(id: "case-a"), modelId: "vec-4")
    #expect(all.count == drafts.count)
    for (pair, draft) in zip(all, drafts) {
        #expect(pair.item.chunkId == ChunkRecord.makeId(textHash: "h-chunk", chunkIndex: draft.chunkIndex))
        #expect(pair.item.content == draft.content)
        #expect(pair.rowid == rowids[draft.chunkIndex])
    }

    try await store.storeChunkEmbeddings(
        [ChunkEmbeddingBatchItem(chunkRowid: rowids[0], embedding: VectorQuantizer.quantize([1, 0, 0, 0]))],
        modelId: "vec-4"
    )
    let remaining = try await store.chunksWithoutEmbeddings(in: .wholeCase(id: "case-a"), modelId: "vec-4")
    #expect(remaining.map(\.rowid) == Array(rowids.dropFirst()))

    let limited = try await store.chunksWithoutEmbeddings(
        in: .wholeCase(id: "case-a"), modelId: "vec-4", limit: 1
    )
    #expect(limited.count == 1)
    #expect(limited[0].rowid == rowids[1])
    _ = temp
}

@Test("embeddingCandidates — только векторы области; topK находит ближайший чанк")
func кандидатыОбластиИБлижайшийВектор() async throws {
    let (temp, store, db) = try await открытьСкладСФикстурой()
    let rowA = try RawFixtures.insertText(db, hash: "h-a", content: "исковое заявление о взыскании")
    let rowB = try RawFixtures.insertText(db, hash: "h-b-scope", content: "протокол собрания кредиторов")
    try RawFixtures.insertWorkspaceDocument(
        db, id: "doc-b", workspaceRootId: "ws", relativePath: "ДелоБ/b.docx", caseId: "case-b"
    )
    try RawFixtures.insertVariant(db, documentId: "doc-a", textHash: "h-a")
    try RawFixtures.insertVariant(db, documentId: "doc-b", textHash: "h-b-scope")

    try await store.registerEmbeddingModel(
        LocalEmbeddingDescriptor(providerId: "test", modelId: "vec-4", dimension: 4, maximumInputTokens: 32)
    )
    let near = VectorQuantizer.quantize([1, 0, 0, 0])
    let far = VectorQuantizer.quantize([0, 1, 0, 0])
    try await store.storeChunkEmbeddings(
        [
            ChunkEmbeddingBatchItem(chunkRowid: rowA[0], embedding: near),
            ChunkEmbeddingBatchItem(chunkRowid: rowB[0], embedding: far),
        ],
        modelId: "vec-4"
    )

    let inCaseA = try await store.embeddingCandidates(in: .wholeCase(id: "case-a"), modelId: "vec-4")
    #expect(inCaseA.map(\.chunkRowid) == [rowA[0]])
    let inCaseB = try await store.embeddingCandidates(in: .wholeCase(id: "case-b"), modelId: "vec-4")
    #expect(inCaseB.map(\.chunkRowid) == [rowB[0]])
    let all = try await store.embeddingCandidates(in: .everything, modelId: "vec-4")
    #expect(Set(all.map(\.chunkRowid)) == Set([rowA[0], rowB[0]]))

    let matches = VectorScan.topK(
        query: [1, 0, 0, 0],
        candidates: all,
        dimension: 4,
        k: 1
    )
    #expect(matches.count == 1)
    #expect(matches[0].chunkRowid == rowA[0])
    #expect(matches[0].score > 0.99)
    _ = temp
}

@Test("embeddings(for:) по умолчанию сохраняет порядок входа")
func пакетныйЭмбеддингПоУмолчаниюСохраняетПорядок() async throws {
    let provider = ПоследовательныйПровайдер()
    let result = try await provider.embeddings(for: ["а", "аб"], purpose: .document)
    #expect(result == [[1, 0], [2, 0]])
}

private struct ПоследовательныйПровайдер: LocalEmbeddingProvider {
    let descriptor = LocalEmbeddingDescriptor(
        providerId: "mock", modelId: "mock", dimension: 2, maximumInputTokens: 8
    )

    func prepare(
        allowDownload: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws {}

    func embedding(for text: String, purpose: LocalEmbeddingPurpose) async throws -> [Float] {
        [Float(text.count), 0]
    }
}

private func открытьСкладСФикстурой() async throws -> (TemporaryDatabase, DocumentIndexStore, SQLite.Connection) {
    let temp = TemporaryDatabase()
    let store = try await temp.openWriter()
    let db = try temp.rawConnection(readonly: false)
    try db.execute("PRAGMA foreign_keys = ON")
    try RawFixtures.insertWorkspaceRoot(db, id: "ws")
    try RawFixtures.insertCase(db, id: "case-a", workspaceRootId: "ws", rootFolderPath: "ДелоА", title: "Дело А")
    try RawFixtures.insertCase(db, id: "case-b", workspaceRootId: "ws", rootFolderPath: "ДелоБ", title: "Дело Б")
    try RawFixtures.insertWorkspaceDocument(
        db, id: "doc-a", workspaceRootId: "ws", relativePath: "ДелоА/a.docx", caseId: "case-a"
    )
    return (temp, store, db)
}

private func слова(_ count: Int, prefix: String = "слово") -> String {
    (1...count).map { "\(prefix)\($0)" }.joined(separator: " ")
}
