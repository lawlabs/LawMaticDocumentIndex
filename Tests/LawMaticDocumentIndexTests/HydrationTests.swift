import Foundation
import SQLite
import Testing
@testable import LawMaticDocumentIndex

@Test("Гидратация по rowid отбрасывает чанк вне области")
func гидратацияУважаетОбласть() async throws {
    let env = try await HydrationEnv()
    try await env.attach(
        documentId: "doc-a", rootId: "root-1", path: "Дело/a.docx",
        text: "Иск о взыскании долга в первом деле."
    )
    try await env.attach(
        documentId: "doc-b", rootId: "root-1", path: "Другое/b.docx",
        text: "Протокол осмотра места происшествия."
    )

    let outside = try await env.store.chunks(textHash: DocumentIndexStore.textHash(of: "Протокол осмотра места происшествия."))
    #expect(outside.count == 1)

    let hydrated = try await env.store.hydrateChunks(
        matches: [VectorMatch(chunkRowid: outside[0].rowid, score: 0.91)],
        scope: .folderPath(workspaceRootId: "root-1", relativePath: "Дело", recursive: true)
    )
    #expect(hydrated.isEmpty)
}

@Test("Копии документов дают две записи с одним chunkId")
func гидратацияКопийДокументов() async throws {
    let env = try await HydrationEnv()
    let content = "Договор уступки права требования к должнику."
    try await env.attach(documentId: "doc-1", rootId: "root-1", path: "Дело/том1.docx", text: content)
    try await env.attach(documentId: "doc-2", rootId: "root-1", path: "Дело/том2.docx", text: content)

    let chunks = try await env.store.chunks(textHash: DocumentIndexStore.textHash(of: content))
    #expect(chunks.count == 1)

    let hydrated = try await env.store.hydrateChunks(
        matches: [VectorMatch(chunkRowid: chunks[0].rowid, score: 0.77)],
        scope: .workspaceRoot(id: "root-1")
    )
    #expect(hydrated.count == 2)
    #expect(Set(hydrated.map(\.chunkId)).count == 1)
    #expect(hydrated[0].chunkId == chunks[0].id)
    #expect(Set(hydrated.map(\.documentId)) == ["doc-1", "doc-2"])
    #expect(hydrated.allSatisfy { $0.source == .semantic })
    #expect(hydrated.allSatisfy { $0.score == 0.77 })
    #expect(hydrated[0].id != hydrated[1].id)
}

@Test("Порядок matches сохраняется, копии идут подряд")
func гидратацияСохраняетПорядокMatches() async throws {
    let env = try await HydrationEnv()
    let first = "Первый уникальный текст про поставку оборудования."
    let second = "Второй уникальный текст про аренду помещения."
    try await env.attach(documentId: "doc-first", rootId: "root-1", path: "Дело/первый.docx", text: first)
    try await env.attach(documentId: "doc-second", rootId: "root-1", path: "Дело/второй.docx", text: second)

    let chunkFirst = try await env.store.chunks(textHash: DocumentIndexStore.textHash(of: first))[0]
    let chunkSecond = try await env.store.chunks(textHash: DocumentIndexStore.textHash(of: second))[0]

    let hydrated = try await env.store.hydrateChunks(
        matches: [
            VectorMatch(chunkRowid: chunkSecond.rowid, score: 0.9),
            VectorMatch(chunkRowid: chunkFirst.rowid, score: 0.4),
        ],
        scope: .everything
    )
    #expect(hydrated.map(\.documentId) == ["doc-second", "doc-first"])
    #expect(hydrated.map(\.score) == [0.9, 0.4])
}

@Test("chunkContext возвращает соседей по индексу и обрезается по краям")
func контекстЧанкаПоИндексуИКраям() async throws {
    let env = try await HydrationEnv()
    let content = слова(480)
    try await env.attach(documentId: "doc-long", rootId: "root-1", path: "Дело/длинный.docx", text: content)
    let chunks = try await env.store.chunks(textHash: DocumentIndexStore.textHash(of: content))
    #expect(chunks.count == 3)

    let middle = try await env.store.chunkContext(
        chunkId: chunks[1].id,
        documentId: "doc-long",
        surroundingChunks: 1
    )
    #expect(middle.map(\.chunkId) == chunks.map(\.id))
    #expect(middle.allSatisfy { $0.documentId == "doc-long" })
    #expect(middle.allSatisfy { $0.source == .lexical && $0.score == 0 })

    let head = try await env.store.chunkContext(
        chunkId: chunks[0].id,
        documentId: "doc-long",
        surroundingChunks: 1
    )
    #expect(head.map(\.chunkId) == [chunks[0].id, chunks[1].id])

    let tail = try await env.store.chunkContext(
        chunkId: chunks[2].id,
        documentId: "doc-long",
        surroundingChunks: 1
    )
    #expect(tail.map(\.chunkId) == [chunks[1].id, chunks[2].id])

    let inferred = try await env.store.chunkContext(
        chunkId: chunks[1].id,
        surroundingChunks: 1
    )
    #expect(inferred.map(\.chunkId) == middle.map(\.chunkId))
}

@Test("chunkRowidsStatement: пустой список — nil, колонки как у FTS")
func запросГидратацииПоRowid() async throws {
    #expect(
        DocumentIndexQuery.chunkRowidsStatement(
            rowids: [],
            variantFilter: .original,
            scope: .everything
        ) == nil
    )

    let env = try await HydrationEnv()
    try await env.attach(
        documentId: "doc-1", rootId: "root-1", path: "Дело/иск.docx",
        text: "Текст договора поставки товара покупателю."
    )
    let hash = DocumentIndexStore.textHash(of: "Текст договора поставки товара покупателю.")
    let rowid = try await env.store.chunks(textHash: hash)[0].rowid

    guard let statement = DocumentIndexQuery.chunkRowidsStatement(
        rowids: [rowid],
        variantFilter: .original,
        scope: .everything
    ) else {
        throw TestFailure("ожидался SQL гидратации")
    }
    #expect(statement.sql.contains("NULL AS rank"))
    #expect(statement.sql.contains("c.rowid IN (?)"))
    #expect(statement.bindings.contains(.integer(rowid)))

    let db = try env.temp.rawConnection()
    var row: [Binding?]?
    for item in try db.prepare(statement.sql, statement.sqliteBindings) {
        row = item
        break
    }
    guard let row else { throw TestFailure("запрос не вернул строк") }
    #expect(row[DocumentIndexQuery.Column.documentId] as? String == "doc-1")
    #expect(row[DocumentIndexQuery.Column.rank] == nil)
}

// MARK: - Фикстуры

private final class HydrationEnv {
    let temp = TemporaryDatabase()
    let store: DocumentIndexStore

    init(roots: [(id: String, localPath: String)] = [("root-1", "/Users/test/РАБОТА")]) async throws {
        store = try await temp.openWriter()
        let db = try temp.rawConnection(readonly: false)
        try db.execute("PRAGMA foreign_keys = ON")
        for root in roots {
            try RawFixtures.insertWorkspaceRoot(db, id: root.id, localPath: root.localPath)
        }
    }

    func attach(documentId: String, rootId: String, path: String, text: String) async throws {
        let db = try temp.rawConnection(readonly: false)
        try db.execute("PRAGMA foreign_keys = ON")
        try RawFixtures.insertWorkspaceDocument(
            db, id: documentId, workspaceRootId: rootId, relativePath: path
        )
        let stored = try await store.storeText(text)
        _ = try await store.setTextVariant(documentId: documentId, type: .original, textHash: stored.textHash)
    }
}

private func слова(_ count: Int, prefix: String = "слово") -> String {
    (1...count).map { "\(prefix)\($0)" }.joined(separator: " ")
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
