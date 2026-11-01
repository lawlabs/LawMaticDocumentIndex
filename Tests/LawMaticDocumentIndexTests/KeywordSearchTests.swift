import Foundation
import SQLite
import Testing
@testable import LawMaticDocumentIndex

@Test("Морфология: взыскание находит «о взыскании неосновательного обогащения»")
func морфологияНаходитДругуюСловоформу() async throws {
    let env = try await SearchEnv()
    try await env.attach(
        documentId: "doc-morph",
        rootId: "root-1",
        path: "Дело/иск.docx",
        text: "Иск о взыскании неосновательного обогащения удовлетворён."
    )

    let result = try await env.store.searchChunksKeyword(
        query: "взыскание неосновательного обогащения",
        scope: .workspaceRoot(id: "root-1")
    )
    #expect(result.hits.count == 1)
    #expect(result.hits[0].documentId == "doc-morph")
    #expect(result.hits[0].content.contains("взыскании"), "фрагмент — оригинал, не основа")
    #expect(result.hits[0].source == .lexical)
    #expect(result.weakestMatchMode == .allWords)
}

@Test("Дата 31.10.2022 находит «31 октября 2022»")
func датаНаходитТекстовуюЗапись() async throws {
    let env = try await SearchEnv()
    try await env.attach(
        documentId: "doc-date",
        rootId: "root-1",
        path: "Дело/протокол.pdf",
        text: "Протокол общего собрания от 31 октября 2022 года."
    )

    let result = try await env.store.searchChunksKeyword(
        query: "31.10.2022",
        scope: .workspaceRoot(id: "root-1")
    )
    #expect(result.hits.count == 1)
    #expect(result.hits[0].documentId == "doc-date")
}

@Test("Одинаковый путь в двух корнях: область одного корня даёт один хит")
func изоляцияРабочегоКорня() async throws {
    let env = try await SearchEnv(roots: [
        ("root-1", "/Users/test/РАБОТА"),
        ("root-2", "/Users/test/ДРУГОЕ"),
    ])
    try await env.attach(
        documentId: "doc-a", rootId: "root-1", path: "Клиенты/договор.docx",
        text: "Договор поставки клиента первого корня."
    )
    try await env.attach(
        documentId: "doc-b", rootId: "root-2", path: "Клиенты/договор.docx",
        text: "Договор поставки клиента второго корня."
    )

    let isolated = try await env.store.searchChunksKeyword(
        query: "договор поставки",
        scope: .workspaceRoot(id: "root-1")
    )
    #expect(isolated.hits.map(\.documentId) == ["doc-a"])

    let all = try await env.store.searchChunksKeyword(
        query: "договор поставки",
        scope: .everything
    )
    #expect(Set(all.hits.map(\.documentId)) == ["doc-a", "doc-b"])
}

@Test("Рекурсивная папка находит вложенные, нерекурсивная — только свою")
func рекурсивнаяПапкаПротивТолькоПапки() async throws {
    let env = try await SearchEnv()
    try await env.attach(
        documentId: "doc-letter", rootId: "root-1", path: "Дело/письмо.docx",
        text: "Сопроводительное письмо по иску о долге."
    )
    try await env.attach(
        documentId: "doc-claim", rootId: "root-1", path: "Дело/Иски/иск.docx",
        text: "Исковое заявление о взыскании долга."
    )

    let recursive = try await env.store.searchChunksKeyword(
        query: "долге",
        scope: .folderPath(workspaceRootId: "root-1", relativePath: "Дело", recursive: true)
    )
    #expect(Set(recursive.hits.map(\.documentId)) == ["doc-letter", "doc-claim"])

    let onlyFolder = try await env.store.searchChunksKeyword(
        query: "долге",
        scope: .folderPath(workspaceRootId: "root-1", relativePath: "Дело", recursive: false)
    )
    #expect(onlyFolder.hits.map(\.documentId) == ["doc-letter"])
}

@Test("Область дела возвращает только документы с case_id")
func областьДела() async throws {
    let env = try await SearchEnv()
    let db = try env.temp.rawConnection(readonly: false)
    try db.execute("PRAGMA foreign_keys = ON")
    try RawFixtures.insertCase(db, id: "case-1", workspaceRootId: "root-1", rootFolderPath: "Дело", title: "Дело")
    try RawFixtures.insertWorkspaceDocument(
        db, id: "doc-in-case", workspaceRootId: "root-1", relativePath: "Дело/иск.docx", caseId: "case-1"
    )
    try RawFixtures.insertWorkspaceDocument(
        db, id: "doc-out", workspaceRootId: "root-1", relativePath: "Другое/акт.docx"
    )
    try await env.attachExisting(documentId: "doc-in-case", text: "Иск внутри дела о взыскании.")
    try await env.attachExisting(documentId: "doc-out", text: "Акт вне дела о взыскании.")

    let result = try await env.store.searchChunksKeyword(
        query: "взыскании",
        scope: .wholeCase(id: "case-1")
    )
    #expect(result.hits.map(\.documentId) == ["doc-in-case"])
}

@Test("Внешние документы видны только в externalOnly и everything")
func внешниеДокументыИзолированы() async throws {
    let env = try await SearchEnv()
    try await env.attach(
        documentId: "doc-ws", rootId: "root-1", path: "Дело/внутренний.docx",
        text: "Внутренний договор поставки."
    )
    let db = try env.temp.rawConnection(readonly: false)
    try db.execute("PRAGMA foreign_keys = ON")
    try RawFixtures.insertExternalDocument(db, id: "doc-ext", absolutePath: "/tmp/внешний-договор.pdf")
    try await env.attachExisting(documentId: "doc-ext", text: "Внешний договор поставки.")

    let external = try await env.store.searchChunksKeyword(
        query: "договор поставки", scope: .externalOnly
    )
    #expect(external.hits.map(\.documentId) == ["doc-ext"])
    #expect(external.hits[0].relativePath == "/tmp/внешний-договор.pdf")
    #expect(external.hits[0].fileURL.path == "/tmp/внешний-договор.pdf")

    let workspace = try await env.store.searchChunksKeyword(
        query: "договор поставки", scope: .workspaceRoot(id: "root-1")
    )
    #expect(workspace.hits.map(\.documentId) == ["doc-ws"])

    let everything = try await env.store.searchChunksKeyword(
        query: "договор поставки", scope: .everything
    )
    #expect(Set(everything.hits.map(\.documentId)) == ["doc-ws", "doc-ext"])
}

@Test("Копия текста в двух документах даёт два хита с одним documentTextHash")
func копияТекстаДваХита() async throws {
    let env = try await SearchEnv()
    let content = "Договор уступки права требования к должнику."
    try await env.attach(documentId: "doc-1", rootId: "root-1", path: "Дело/том1.docx", text: content)
    try await env.attach(documentId: "doc-2", rootId: "root-1", path: "Дело/том2.docx", text: content)

    let result = try await env.store.searchChunksKeyword(
        query: "договор уступки",
        scope: .workspaceRoot(id: "root-1")
    )
    #expect(result.hits.count == 2)
    #expect(Set(result.hits.map(\.documentId)) == ["doc-1", "doc-2"])
    #expect(Set(result.hits.map(\.documentTextHash)).count == 1)
    #expect(result.hits[0].documentTextHash == DocumentIndexStore.textHash(of: content))
    #expect(result.hits[0].id != result.hits[1].id)
}

@Test("Каскад дополняет строгую ступень ослабленной, weakestMatchMode == anyWord")
func каскадДобавляетОслабленные() async throws {
    let env = try await SearchEnv()
    try await env.attach(
        documentId: "doc-full-1", rootId: "root-1", path: "Дело/полный1.docx",
        text: "Иск о взыскании неосновательного обогащения по первому эпизоду."
    )
    try await env.attach(
        documentId: "doc-full-2", rootId: "root-1", path: "Дело/полный2.docx",
        text: "Иск о взыскании неосновательного обогащения по второму эпизоду."
    )
    for index in 1...12 {
        try await env.attach(
            documentId: "doc-partial-\(index)",
            rootId: "root-1",
            path: "Дело/частичный-\(index).docx",
            text: "Требование о взыскании долга номер \(index) без прочих оснований."
        )
    }

    let result = try await env.store.searchChunksKeyword(
        query: "взыскание неосновательного обогащения",
        scope: .workspaceRoot(id: "root-1"),
        limit: 20
    )
    #expect(result.hits.count > 2, "к двум строгим добавились ослабленные")
    #expect(result.hits.count <= 20)
    #expect(result.weakestMatchMode == .anyWord)
    let leading = Set(result.hits.prefix(2).map(\.documentId))
    #expect(leading.isSubset(of: ["doc-full-1", "doc-full-2"]), "строгие совпадения выше")
}

@Test("Каскад набирает до limit различных чанков; копии одного текста не вытесняют следующую ступень")
func каскадСчитаетРазличныеЧанки() async throws {
    let env = try await SearchEnv()
    // 13 копий одного протокола: строгая ступень даёт 13 строк на один чанк.
    let protocolText = "Протокол общего собрания собственников об утверждении сметы расходов."
    for index in 1...13 {
        try await env.attach(
            documentId: "doc-copy-\(index)", rootId: "root-1",
            path: "Дело/копия-\(index)/протокол.pdf", text: protocolText
        )
    }
    for index in 1...15 {
        try await env.attach(
            documentId: "doc-other-\(index)", rootId: "root-1",
            path: "Дело/прочее-\(index).docx",
            text: "Смета расходов номер \(index) на текущий ремонт подъезда."
        )
    }

    let result = try await env.store.searchChunksKeyword(
        query: "протокол собрания смета",
        scope: .workspaceRoot(id: "root-1"),
        limit: 12
    )
    let distinctChunks = Set(result.hits.map(\.chunkId))
    #expect(distinctChunks.count == 12, "limit — по различным чанкам, а не по парам чанк/документ")
    #expect(result.hits.filter { $0.documentId.hasPrefix("doc-copy-") }.count == 13, "копии остаются все")
    #expect(result.hits.contains { $0.documentId.hasPrefix("doc-other-") }, "ослабленная ступень запустилась")
    #expect(result.weakestMatchMode == .anyWord)

    let strict = try await env.store.searchChunksKeyword(
        query: "протокол собрания смета",
        scope: .workspaceRoot(id: "root-1"),
        limit: 1
    )
    #expect(strict.hits.count == 13, "один чанк со всеми копиями")
    #expect(Set(strict.hits.map(\.chunkId)).count == 1)
}

@Test("Подстрочная ступень находит инфикс, которого нет в FTS")
func подстрочнаяСтупеньНаходитИнфикс() async throws {
    let env = try await SearchEnv()
    try await env.attach(
        documentId: "doc-code",
        rootId: "root-1",
        path: "Дело/шифр.docx",
        text: "Номер договора ABCXYZQWERTY указан в приложении."
    )

    let result = try await env.store.searchChunksKeyword(
        query: "CXYZQW",
        scope: .workspaceRoot(id: "root-1")
    )
    #expect(result.hits.map(\.documentId) == ["doc-code"])
    #expect(result.weakestMatchMode == .substring)
    #expect(result.hits[0].content.contains("ABCXYZQWERTY"))
    #expect(result.hits[0].score == 0)
}

@Test("fileURL собирается из local_path корня и relative_path")
func fileURLИзКорня() async throws {
    let env = try await SearchEnv(roots: [("root-1", "/Users/test/РАБОТА")])
    try await env.attach(
        documentId: "doc-url",
        rootId: "root-1",
        path: "Дело/иск.docx",
        text: "Исковое заявление в рабочем корне."
    )

    let result = try await env.store.searchChunksKeyword(
        query: "исковое заявление",
        scope: .workspaceRoot(id: "root-1")
    )
    #expect(result.hits.count == 1)
    #expect(result.hits[0].fileURL.path == "/Users/test/РАБОТА/Дело/иск.docx")
    #expect(result.hits[0].relativePath == "Дело/иск.docx")
    #expect(result.hits[0].fileName == "иск.docx")
}

@Test("EXPLAIN QUERY PLAN рекурсивной папки не сканирует documents")
func планFtsРекурсивнойПапкиБезScanDocuments() async throws {
    let env = try await SearchEnv()
    try await env.attach(
        documentId: "doc-1", rootId: "root-1", path: "Дело/письмо.docx",
        text: "Письмо о договоре поставки."
    )
    try await env.attach(
        documentId: "doc-2", rootId: "root-1", path: "Дело/Иски/иск.docx",
        text: "Иск о договоре поставки."
    )
    try await env.attach(
        documentId: "doc-3", rootId: "root-1", path: "Другое/акт.docx",
        text: "Акт о договоре поставки."
    )

    let stems = RussianTextNormalizer.queryStems(from: "договор поставки")
    guard let statement = DocumentIndexQuery.ftsStatement(
        stems: stems,
        mode: .allWords,
        variantFilter: .original,
        scope: .folderPath(workspaceRootId: "root-1", relativePath: "Дело", recursive: true),
        limit: 20
    ) else {
        throw TestFailure("не собрался FTS-запрос")
    }

    let db = try env.temp.rawConnection()
    let plan = try queryPlan(db, statement.sql, statement.sqliteBindings.compactMap { $0 })
    let fullScan = plan.contains { $0 == "SCAN d" || $0.hasPrefix("SCAN d ") || $0.hasPrefix("SCAN documents") }
    #expect(!fullScan, "план без полного просмотра documents: \(plan)")
}

@Test("Запрос по имени файла находит документ и ставит его выше совпадения только в тексте")
func имяФайлаВИндексеЧанковИВесBm25() async throws {
    let env = try await SearchEnv()
    try await env.attach(
        documentId: "doc-by-name",
        rootId: "root-1",
        path: "Дело/Протокол ОСС от 31.10.2022.pdf",
        text: "Решение правления о текущем ремонте кровли и утверждении сметы."
    )
    try await env.attach(
        documentId: "doc-by-text",
        rootId: "root-1",
        path: "Дело/письмо.docx",
        text: "В приложении указан протокол ОСС от 31.10.2022 по текущему ремонту."
    )

    let result = try await env.store.searchChunksKeyword(
        query: "протокол ОСС 31.10.2022",
        scope: .workspaceRoot(id: "root-1")
    )
    #expect(result.weakestMatchMode == .allWords)
    #expect(result.hits.map(\.documentId).contains("doc-by-name"))
    #expect(result.hits.map(\.documentId).contains("doc-by-text"))
    #expect(result.hits[0].documentId == "doc-by-name", "имя файла весит 5 против 1 у текста")
}

@Test("Копия текста под другим именем ищется по имени второго документа")
func копияТекстаИщетсяПоИмениВторогоДокумента() async throws {
    let env = try await SearchEnv()
    let content = "Решение правления о текущем ремонте кровли без упоминания собрания."
    try await env.attach(
        documentId: "doc-orig", rootId: "root-1",
        path: "Дело/решение-правления.pdf", text: content
    )
    try await env.attach(
        documentId: "doc-copy", rootId: "root-1",
        path: "Дело/Протокол ОСС копия.pdf", text: content
    )

    let result = try await env.store.searchChunksKeyword(
        query: "протокол ОСС",
        scope: .workspaceRoot(id: "root-1")
    )
    #expect(result.weakestMatchMode == .allWords)
    #expect(Set(result.hits.map(\.documentId)) == ["doc-copy"])
}

@Test("После переименования старое имя больше не находится, новое находится")
func переименованиеОбновляетИмяВChunkFTS() async throws {
    let env = try await SearchEnv()
    try await env.attach(
        documentId: "doc-rename",
        rootId: "root-1",
        path: "Дело/Протокол ОСС от 31.10.2022.pdf",
        text: "Решение правления о текущем ремонте кровли."
    )

    let before = try await env.store.searchChunksKeyword(
        query: "протокол ОСС 31.10.2022",
        scope: .workspaceRoot(id: "root-1")
    )
    #expect(before.hits.map(\.documentId) == ["doc-rename"])

    _ = try await env.store.moveDocument(
        id: "doc-rename",
        toWorkspaceRootId: "root-1",
        relativePath: "Дело/смета-ремонта.pdf"
    )

    let oldName = try await env.store.searchChunksKeyword(
        query: "протокол ОСС 31.10.2022",
        scope: .workspaceRoot(id: "root-1")
    )
    #expect(oldName.hits.isEmpty, "старое имя ушло из chunk_fts")

    let newName = try await env.store.searchChunksKeyword(
        query: "смета ремонта",
        scope: .workspaceRoot(id: "root-1")
    )
    #expect(newName.hits.map(\.documentId) == ["doc-rename"])
}

@Test("Удаление одной из копий убирает её имя из FTS, вторая остаётся")
func удалениеКопииУбираетИмяИзFTS() async throws {
    let env = try await SearchEnv()
    let content = "Решение правления о текущем ремонте кровли без характерных слов."
    try await env.attach(
        documentId: "doc-keep", rootId: "root-1",
        path: "Дело/решение-правления.pdf", text: content
    )
    try await env.attach(
        documentId: "doc-drop", rootId: "root-1",
        path: "Дело/Протокол ОСС копия.pdf", text: content
    )

    try await env.store.removeTextVariant(documentId: "doc-drop", type: .original)
    let afterRemove = try await env.store.searchChunksKeyword(
        query: "протокол ОСС",
        scope: .workspaceRoot(id: "root-1")
    )
    #expect(afterRemove.hits.isEmpty, "имя снятого варианта больше не ищется")
    let keptAfterRemove = try await env.store.searchChunksKeyword(
        query: "решение правления",
        scope: .workspaceRoot(id: "root-1")
    )
    #expect(keptAfterRemove.hits.map(\.documentId) == ["doc-keep"])

    _ = try await env.store.setTextVariant(
        documentId: "doc-drop", type: .original,
        textHash: DocumentIndexStore.textHash(of: content)
    )
    try await env.store.deleteDocument(id: "doc-drop")

    let afterDelete = try await env.store.searchChunksKeyword(
        query: "протокол ОСС",
        scope: .workspaceRoot(id: "root-1")
    )
    #expect(afterDelete.hits.isEmpty)
    let kept = try await env.store.searchChunksKeyword(
        query: "решение правления",
        scope: .workspaceRoot(id: "root-1")
    )
    #expect(kept.hits.map(\.documentId) == ["doc-keep"])
}

@Test("Среди копий одного текста первой идёт документ с именем под запрос")
func копииСортируютсяПоСовпадениюИмени() async throws {
    let env = try await SearchEnv()
    let content = "Решение правления о текущем ремонте кровли без слов собрания."
    try await env.attach(
        documentId: "doc-generic", rootId: "root-1",
        path: "Дело/приложение-7.pdf", text: content
    )
    try await env.attach(
        documentId: "doc-named", rootId: "root-1",
        path: "Дело/Копия протокола ОСС от 31.10.2022.pdf", text: content
    )

    let result = try await env.store.searchChunksKeyword(
        query: "протокол ОСС 31.10.2022",
        scope: .workspaceRoot(id: "root-1")
    )
    #expect(result.hits.map(\.documentId) == ["doc-named"])
    let diversified = SearchToolPresentation.diversifiedResults(result.hits, limit: 10)
    #expect(diversified.map(\.documentId) == ["doc-named"], "выдача для ИИ оставляет копию с лучшим именем")
}

@Test("attachText пишет FTS с именем и не пересобирает индекс нового текста")
func attachTextПишетFTSБезДвойнойПересборки() async throws {
    let env = try await SearchEnv()
    let db = try env.temp.rawConnection(readonly: false)
    try db.execute("PRAGMA foreign_keys = ON")
    try RawFixtures.insertWorkspaceDocument(
        db, id: "doc-attach", workspaceRootId: "root-1",
        relativePath: "Дело/Протокол ОСС от 31.10.2022.pdf"
    )
    try RawFixtures.insertWorkspaceDocument(
        db, id: "doc-legacy", workspaceRootId: "root-1",
        relativePath: "Дело/Протокол ОСС дубль.pdf"
    )

    let content = "Решение правления о текущем ремонте кровли."
    let attached = try await env.store.attachText(documentId: "doc-attach", content: content)
    #expect(attached.text.isNew)
    #expect(await env.store.chunkFTSRebuildCount == 0, "новый текст не переписывает FTS повторно")

    let byName = try await env.store.searchChunksKeyword(
        query: "протокол ОСС 31.10.2022",
        scope: .workspaceRoot(id: "root-1")
    )
    #expect(byName.hits.map(\.documentId) == ["doc-attach"])
    #expect(byName.weakestMatchMode == .allWords)

    let rebuildsBeforeCopy = await env.store.chunkFTSRebuildCount
    let stored = try await env.store.storeText(content)
    #expect(stored.isNew == false)
    #expect(stored.textHash == attached.text.textHash)
    _ = try await env.store.setTextVariant(
        documentId: "doc-legacy", type: .original, textHash: stored.textHash
    )
    #expect(await env.store.chunkFTSRebuildCount == rebuildsBeforeCopy + 1, "копия пересобирает FTS")

    let both = try await env.store.searchChunksKeyword(
        query: "протокол ОСС",
        scope: .workspaceRoot(id: "root-1")
    )
    #expect(Set(both.hits.map(\.documentId)) == ["doc-attach", "doc-legacy"])
}

// MARK: - Фикстуры

private final class SearchEnv {
    let temp = TemporaryDatabase()
    let store: DocumentIndexStore

    init(roots: [(id: String, localPath: String)] = [("root-1", "/Users/test/РАБОТА")]) async throws {
        store = try await temp.openWriter()
        try await store.setWorkspacePaths(Dictionary(uniqueKeysWithValues: roots.map { ($0.id, $0.localPath) }))
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
        try await attachExisting(documentId: documentId, text: text)
    }

    func attachExisting(documentId: String, text: String) async throws {
        let stored = try await store.storeText(text)
        _ = try await store.setTextVariant(documentId: documentId, type: .original, textHash: stored.textHash)
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
