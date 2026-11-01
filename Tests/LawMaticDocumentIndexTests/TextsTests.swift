import Foundation
import SQLite
import Testing
@testable import LawMaticDocumentIndex

@Test("Хеш текста — SHA-256 hex нижнего регистра от UTF-8")
func хешТекстаSha256() {
    #expect(DocumentIndexStore.textHash(of: "abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    #expect(DocumentIndexStore.textHash(of: "") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
}

@Test("Повтор storeText с тем же содержимым не пишет чанки и FTS")
func повторStoreTextНеПишет() async throws {
    let temp = TemporaryDatabase()
    let store = try await temp.openWriter()
    let content = "Исковое заявление о взыскании задолженности по договору."
    let first = try await store.storeText(content)
    #expect(first.isNew)
    #expect(first.chunkCount == SearchChunker.chunks(from: content).count)
    #expect(first.textHash == DocumentIndexStore.textHash(of: content))

    let second = try await store.storeText(content)
    #expect(second.isNew == false)
    #expect(second.textHash == first.textHash)
    #expect(second.chunkCount == first.chunkCount)

    await store.close()
    let db = try temp.rawConnection()
    #expect(try db.scalar("SELECT COUNT(*) FROM texts") as? Int64 == 1)
    #expect(try db.scalar("SELECT COUNT(*) FROM chunks") as? Int64 == Int64(first.chunkCount))
    #expect(try ftsRowCount(db) == Int64(first.chunkCount))
}

@Test("Пустой и пробельный текст хранится без чанков")
func пустойТекстБезЧанков() async throws {
    let temp = TemporaryDatabase()
    let store = try await temp.openWriter()
    let empty = try await store.storeText("")
    #expect(empty.isNew)
    #expect(empty.chunkCount == 0)
    #expect(empty.utf16Length == 0)

    let spaces = try await store.storeText("   \n\t")
    #expect(spaces.isNew)
    #expect(spaces.chunkCount == 0)
    #expect(try await store.chunks(textHash: spaces.textHash).isEmpty)
}

@Test("Страницы проставляют page_number чанков по utf16Start")
func страницыПроставляютНомерЧанка() async throws {
    let temp = TemporaryDatabase()
    let store = try await temp.openWriter()
    let page1 = (1...50).map { "слово\($0)" }.joined(separator: " ")
    let page2 = (51...220).map { "слово\($0)" }.joined(separator: " ")
    let content = page1 + " " + page2
    let page2Start = (page1 as NSString).length + 1
    let pages = [
        TextPageRange(pageNumber: 1, utf16Start: 0, utf16End: page2Start),
        TextPageRange(pageNumber: 2, utf16Start: page2Start, utf16End: (content as NSString).length),
    ]

    let stored = try await store.storeText(content, pages: pages)
    #expect(stored.chunkCount >= 2)
    let chunks = try await store.chunks(textHash: stored.textHash)
    #expect(try await store.textPages(hash: stored.textHash).count == 2)

    let drafts = SearchChunker.chunks(from: content)
    #expect(chunks.count == drafts.count)
    for (chunk, draft) in zip(chunks, drafts) {
        let expectedPage = draft.utf16Start < page2Start ? 1 : 2
        #expect(chunk.pageNumber == expectedPage, "чанк \(chunk.chunkIndex) стартует на стр. \(expectedPage)")
        #expect(try await store.chunkContent(chunk) == draft.content)
        #expect(try await store.chunk(id: chunk.id)?.rowid == chunk.rowid)
        #expect(try await store.chunk(rowid: chunk.rowid)?.id == chunk.id)
    }
}

@Test("Замена варианта сохраняет прежний текст в истории, вне текущего поиска")
func заменаВариантаСобираетСироту() async throws {
    let temp = TemporaryDatabase()
    let store = try await temp.openWriter()
    try await seedWorkspace(temp, documentId: "doc-1", path: "Дело/иск.docx")

    let oldText = try await store.storeText("Старый текст иска о долге.")
    _ = try await store.setTextVariant(documentId: "doc-1", type: .original, textHash: oldText.textHash)
    let newText = try await store.storeText("Новый текст иска о взыскании.")
    let variant = try await store.setTextVariant(documentId: "doc-1", type: .original, textHash: newText.textHash)

    #expect(variant.textHash == newText.textHash)
    #expect(try await store.currentTextHash(documentId: "doc-1", type: .original) == newText.textHash)
    #expect(try await store.textRecord(hash: oldText.textHash) != nil, "прежний текст жив до сборки сирот")
    #expect(try await store.collectOrphanTexts() == 0)
    #expect(try await store.textRecord(hash: oldText.textHash) != nil)
    #expect(try await store.searchChunksKeyword(query: "старый", scope: .everything).hits.isEmpty)
    let raw = try temp.rawConnection()
    #expect(try raw.scalar("SELECT COUNT(*) FROM text_variant_history") as? Int64 == 1)
    #expect(try await store.textRecord(hash: newText.textHash) != nil)
    #expect(try await store.documentText(documentId: "doc-1") == "Новый текст иска о взыскании.")
}

@Test("Два документа с одним хешем делят один текст и одни чанки")
func дваДокументаОдинТекст() async throws {
    let temp = TemporaryDatabase()
    let store = try await temp.openWriter()
    try await seedWorkspace(temp, documents: [
        ("doc-1", "Дело/копия-а.docx"),
        ("doc-2", "Дело/копия-б.docx"),
    ])

    let content = "Один и тот же договор поставки в двух томах дела."
    let stored = try await store.storeText(content)
    _ = try await store.setTextVariant(documentId: "doc-1", type: .original, textHash: stored.textHash)
    let again = try await store.storeText(content)
    #expect(again.isNew == false)
    _ = try await store.setTextVariant(documentId: "doc-2", type: .original, textHash: again.textHash)

    #expect(try await store.textVariants(documentId: "doc-1").count == 1)
    #expect(try await store.textVariants(documentId: "doc-2").count == 1)
    #expect(try await store.chunks(textHash: stored.textHash).count == stored.chunkCount)
    #expect(try await store.documentText(documentId: "doc-1") == content)
    #expect(try await store.documentText(documentId: "doc-2") == content)

    await store.close()
    let db = try temp.rawConnection()
    #expect(try db.scalar("SELECT COUNT(*) FROM texts") as? Int64 == 1)
    #expect(try db.scalar("SELECT COUNT(*) FROM chunks") as? Int64 == Int64(stored.chunkCount))
}

@Test("chunkCount считает уникальные чанки по области и фильтру варианта")
func chunkCountПоОбластиИВарианту() async throws {
    let temp = TemporaryDatabase()
    let store = try await temp.openWriter()
    try await seedWorkspace(temp, documents: [
        ("doc-folder", "Дело/письмо.docx"),
        ("doc-nested", "Дело/Иски/иск.docx"),
        ("doc-other", "Другое/акт.docx"),
    ])
    let db = try temp.rawConnection(readonly: false)
    try RawFixtures.insertExternalDocument(db, id: "doc-ext", absolutePath: "/tmp/внешний.pdf")

    let originalA = try await store.storeText("Исходный текст письма в папке Дело.")
    let originalB = try await store.storeText("Исходный текст иска во вложенной папке.")
    let originalC = try await store.storeText("Исходный текст акта в другой ветке.")
    let originalExt = try await store.storeText("Исходный текст внешнего файла.")
    let anonymizedA = try await store.storeText("Обезличенный текст письма без имён сторон.")

    _ = try await store.setTextVariant(documentId: "doc-folder", type: .original, textHash: originalA.textHash)
    _ = try await store.setTextVariant(documentId: "doc-folder", type: .anonymized, textHash: anonymizedA.textHash)
    _ = try await store.setTextVariant(documentId: "doc-nested", type: .original, textHash: originalB.textHash)
    _ = try await store.setTextVariant(documentId: "doc-other", type: .original, textHash: originalC.textHash)
    _ = try await store.setTextVariant(documentId: "doc-ext", type: .original, textHash: originalExt.textHash)

    let folderCount = originalA.chunkCount
    let nestedCount = originalB.chunkCount
    let otherCount = originalC.chunkCount
    let extCount = originalExt.chunkCount
    let anonCount = anonymizedA.chunkCount

    #expect(
        try await store.chunkCount(
            in: .folderPath(workspaceRootId: "root-1", relativePath: "Дело", recursive: false)
        ) == folderCount
    )
    #expect(
        try await store.chunkCount(
            in: .folderPath(workspaceRootId: "root-1", relativePath: "Дело", recursive: true)
        ) == folderCount + nestedCount
    )
    #expect(try await store.chunkCount(in: .externalOnly) == extCount)
    #expect(
        try await store.chunkCount(in: .everything, variantFilter: .original)
            == folderCount + nestedCount + otherCount + extCount
    )
    #expect(try await store.chunkCount(in: .everything, variantFilter: .anonymized) == anonCount)
    #expect(
        try await store.chunkCount(in: .everything, variantFilter: .all)
            == folderCount + nestedCount + otherCount + extCount + anonCount
    )
    #expect(try await store.documentText(documentId: "doc-folder", type: .anonymized) == "Обезличенный текст письма без имён сторон.")
}

@Test("setTextVariant на отсутствующий документ бросает notFound")
func setTextVariantНаОтсутствующийДокумент() async throws {
    let temp = TemporaryDatabase()
    let store = try await temp.openWriter()
    let stored = try await store.storeText("Текст без документа.")
    await #expect(throws: DocumentIndexError.notFound("нет-такого")) {
        try await store.setTextVariant(documentId: "нет-такого", type: .original, textHash: stored.textHash)
    }
}

@Test("Два документа с общим хешем: chunkCount не удваивает чанки")
func chunkCountНеУдваиваетОбщийТекст() async throws {
    let temp = TemporaryDatabase()
    let store = try await temp.openWriter()
    try await seedWorkspace(temp, documents: [
        ("doc-1", "Дело/а.docx"),
        ("doc-2", "Дело/б.docx"),
    ])
    let stored = try await store.storeText("Общий текст двух копий договора.")
    _ = try await store.setTextVariant(documentId: "doc-1", type: .original, textHash: stored.textHash)
    _ = try await store.setTextVariant(documentId: "doc-2", type: .original, textHash: stored.textHash)
    #expect(try await store.chunkCount(in: .everything) == stored.chunkCount)
}

private func seedWorkspace(
    _ temp: TemporaryDatabase,
    documentId: String = "doc-1",
    path: String = "Дело/файл.docx"
) async throws {
    try await seedWorkspace(temp, documents: [(documentId, path)])
}

private func seedWorkspace(_ temp: TemporaryDatabase, documents: [(String, String)]) async throws {
    let db = try temp.rawConnection(readonly: false)
    try db.execute("PRAGMA foreign_keys = ON")
    try RawFixtures.insertWorkspaceRoot(db, id: "root-1")
    for (id, path) in documents {
        try RawFixtures.insertWorkspaceDocument(db, id: id, workspaceRootId: "root-1", relativePath: path)
    }
}

private func ftsRowCount(_ db: SQLite.Connection) throws -> Int64 {
    var count: Int64 = 0
    for _ in try db.prepare("SELECT rowid FROM chunk_fts") {
        count += 1
    }
    return count
}
