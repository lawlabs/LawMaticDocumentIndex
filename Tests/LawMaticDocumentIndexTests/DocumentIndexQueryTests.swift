import Foundation
import SQLite
import Testing
@testable import LawMaticDocumentIndex

@Test("CTE появляется только у рекурсивных областей")
func cteТолькоУРекурсивныхОбластей() {
    let stems = ["договор"]

    let recursiveFolder = DocumentIndexQuery.ftsStatement(
        stems: stems, mode: .allWords, variantFilter: .original,
        scope: .folder(id: 2, recursive: true), limit: 10
    )
    let recursivePath = DocumentIndexQuery.ftsStatement(
        stems: stems, mode: .allWords, variantFilter: .original,
        scope: .folderPath(workspaceRootId: "root-1", relativePath: "Дело", recursive: true), limit: 10
    )
    let folderOnly = DocumentIndexQuery.ftsStatement(
        stems: stems, mode: .allWords, variantFilter: .original,
        scope: .folder(id: 2, recursive: false), limit: 10
    )
    let pathOnly = DocumentIndexQuery.ftsStatement(
        stems: stems, mode: .allWords, variantFilter: .original,
        scope: .folderPath(workspaceRootId: "root-1", relativePath: "Дело", recursive: false), limit: 10
    )
    let everything = DocumentIndexQuery.ftsStatement(
        stems: stems, mode: .allWords, variantFilter: .original,
        scope: .everything, limit: 10
    )
    let wholeCase = DocumentIndexQuery.ftsStatement(
        stems: stems, mode: .allWords, variantFilter: .original,
        scope: .wholeCase(id: "case-1"), limit: 10
    )

    #expect(recursiveFolder?.sql.contains("WITH RECURSIVE") == true)
    #expect(recursiveFolder?.sql.contains(ScopeSQL.folderCTEName) == true)
    #expect(recursivePath?.sql.contains("WITH RECURSIVE") == true)
    #expect(folderOnly?.sql.contains("WITH RECURSIVE") != true)
    #expect(pathOnly?.sql.contains("WITH RECURSIVE") != true)
    #expect(everything?.sql.contains("WITH RECURSIVE") != true)
    #expect(wholeCase?.sql.contains("WITH RECURSIVE") != true)
    #expect(
        everything?.sql.contains("bm25(chunk_fts, 0.0, 1.0)") == true,
        "ранжирование как в v1: имя файла весит 5"
    )
}

@Test("Фильтр варианта добавляет условие, .all — нет")
func фильтрВариантаДобавляетУсловие() {
    let stems = ["договор"]
    let original = DocumentIndexQuery.ftsStatement(
        stems: stems, mode: .allWords, variantFilter: .original,
        scope: .everything, limit: 5
    )
    let anonymized = DocumentIndexQuery.ftsStatement(
        stems: stems, mode: .allWords, variantFilter: .anonymized,
        scope: .everything, limit: 5
    )
    let all = DocumentIndexQuery.ftsStatement(
        stems: stems, mode: .allWords, variantFilter: .all,
        scope: .everything, limit: 5
    )

    #expect(original?.sql.contains("tv.variant_type = ?") == true)
    #expect(original?.bindings.contains(.text("original")) == true)
    #expect(anonymized?.sql.contains("tv.variant_type = ?") == true)
    #expect(anonymized?.bindings.contains(.text("anonymized")) == true)
    #expect(all?.sql.contains("tv.variant_type = ?") != true)
    #expect(all?.bindings.contains(.text("original")) != true)
}

@Test("Пустые основы и однословный anyWord не строят FTS")
func пустыеОсновыДаютNil() {
    #expect(
        DocumentIndexQuery.ftsStatement(
            stems: [], mode: .allWords, variantFilter: .original,
            scope: .everything, limit: 10
        ) == nil
    )
    #expect(
        DocumentIndexQuery.ftsStatement(
            stems: ["договор"], mode: .anyWord, variantFilter: .original,
            scope: .everything, limit: 10
        ) == nil,
        "ослабленная ступень на одном слове совпала бы со строгой"
    )
    #expect(
        DocumentIndexQuery.substringStatement(
            query: "аб", variantFilter: .original, scope: .everything, limit: 10
        ) == nil
    )
    #expect(
        DocumentIndexQuery.substringStatement(
            query: "   ", variantFilter: .original, scope: .everything, limit: 10
        ) == nil
    )
}

@Test("Порядок колонок FTS и подстроки совпадает с контрактом на живой базе")
func порядокКолонокСтабиленНаЖивойБазе() async throws {
    let env = try await QueryTestEnv()
    let stems = RussianTextNormalizer.queryStems(from: "договор поставки")

    guard let fts = DocumentIndexQuery.ftsStatement(
        stems: stems, mode: .allWords, variantFilter: .original,
        scope: .everything, limit: 10
    ) else {
        throw TestFailure("не собрался FTS-запрос")
    }
    let ftsRow = try env.firstRow(fts)
    #expect(ftsRow[DocumentIndexQuery.Column.chunkId] as? String == ChunkRecord.makeId(textHash: env.hash, chunkIndex: 0))
    #expect(ftsRow[DocumentIndexQuery.Column.textHash] as? String == env.hash)
    #expect(ftsRow[DocumentIndexQuery.Column.chunkIndex] as? Int64 == 0)
    #expect(ftsRow[DocumentIndexQuery.Column.documentId] as? String == "doc-1")
    #expect(ftsRow[DocumentIndexQuery.Column.locationKind] as? String == "workspace")
    #expect(ftsRow[DocumentIndexQuery.Column.workspaceRootId] as? String == "root-1")
    #expect(ftsRow[DocumentIndexQuery.Column.relativePath] as? String == "Дело/договор.docx")
    #expect(ftsRow[DocumentIndexQuery.Column.fileName] as? String == "договор.docx")
    #expect(ftsRow[DocumentIndexQuery.Column.variantType] as? String == "original")
    #expect(ftsRow[DocumentIndexQuery.Column.rank] as? Double != nil, "FTS отдаёт bm25")

    guard let substring = DocumentIndexQuery.substringStatement(
        query: "договора поставки", variantFilter: .original,
        scope: .everything, limit: 10
    ) else {
        throw TestFailure("не собрался подстрочный запрос")
    }
    let subRow = try env.firstRow(substring)
    #expect(subRow[DocumentIndexQuery.Column.documentId] as? String == "doc-1")
    #expect(subRow[DocumentIndexQuery.Column.textHash] as? String == env.hash)
    #expect(subRow[DocumentIndexQuery.Column.chunkIndex] as? Int64 == 0)
    #expect(subRow[DocumentIndexQuery.Column.rank] == nil, "подстрочная ступень без ранга")
}

@Test("Подстрочная ступень выбирает нулевой чанк подходящего текста")
func подстрочнаяСтупеньБерётНулевойЧанк() {
    guard let statement = DocumentIndexQuery.substringStatement(
        query: "РН-17/2", variantFilter: .original, scope: .everything, limit: 5
    ) else {
        Issue.record("ожидался SQL подстроки")
        return
    }
    #expect(statement.sql.contains("c.chunk_index = 0"))
    #expect(statement.sql.contains("LIKE ? ESCAPE"))
    #expect(statement.bindings.contains(.text("%РН-17/2%")))
}

private struct QueryTestEnv {
    let temp = TemporaryDatabase()
    let db: SQLite.Connection
    let hash: String

    init() async throws {
        let store = try await temp.openWriter()
        await store.close()
        db = try temp.rawConnection(readonly: false)
        try db.execute("PRAGMA foreign_keys = ON")
        try RawFixtures.insertWorkspaceRoot(db, id: "root-1")
        try RawFixtures.insertWorkspaceDocument(
            db, id: "doc-1", workspaceRootId: "root-1", relativePath: "Дело/договор.docx"
        )
        let content = "Текст договора поставки товара покупателю."
        hash = DocumentIndexStore.textHash(of: content)
        _ = try RawFixtures.insertText(db, hash: hash, content: content)
        try RawFixtures.insertVariant(db, documentId: "doc-1", textHash: hash)
    }

    func firstRow(_ statement: DocumentIndexQuery.Statement) throws -> [Binding?] {
        for row in try db.prepare(statement.sql, statement.sqliteBindings) {
            return row
        }
        throw TestFailure("запрос не вернул строк: \(statement.sql)")
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
