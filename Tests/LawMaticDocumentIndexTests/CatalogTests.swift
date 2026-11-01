import Foundation
import SQLite
import Testing
@testable import LawMaticDocumentIndex

@Test("Регистрация корня создаёт корневую папку; повтор по тому же пути не дублирует")
func регистрацияКорняИдемпотентна() async throws {
    let fixture = try await CatalogFixture.open()
    let store = fixture.store
    let root = fixture.root

    #expect(root.localPath == "/Users/test/РАБОТА")
    #expect(root.ownerApp == "lawmatic-finder")

    let folder = try await store.folder(workspaceRootId: root.id, relativePath: "")
    #expect(folder?.parentId == nil)
    #expect(folder?.depth == 0)
    #expect(folder?.relativePath == "")

    let again = try await store.registerWorkspaceRoot(
        name: "Работа 2",
        localPath: "/Users/test/РАБОТА/"
    )
    #expect(again.id == root.id)
    #expect(again.name == "Работа 2")
    #expect(try await store.workspaceRoots().count == 1)
    #expect(try await store.workspaceRoot(localPath: "/Users/test/РАБОТА/")?.id == root.id)

    await store.close()
    let db = try fixture.temp.rawConnection()
    #expect(try db.scalar("SELECT COUNT(*) FROM folders") as? Int64 == 1)
}

@Test("ensureFolder строит цепочку без дублей; ancestorFolders идёт от родителя к корню")
func цепочкаПапокИПредки() async throws {
    let fixture = try await CatalogFixture.open()
    let store = fixture.store

    let deepest = try await store.ensureFolder(
        workspaceRootId: fixture.root.id,
        relativePath: "Клиент/Дело/Иски"
    )
    #expect(deepest.relativePath == "Клиент/Дело/Иски")
    #expect(deepest.depth == 3)

    let again = try await store.ensureFolder(
        workspaceRootId: fixture.root.id,
        relativePath: "Клиент/Дело/Иски"
    )
    #expect(again.id == deepest.id)

    let ancestors = try await store.ancestorFolders(of: deepest.id)
    #expect(ancestors.map(\.relativePath) == ["Клиент/Дело", "Клиент", ""])

    let parent = try await store.folder(workspaceRootId: fixture.root.id, relativePath: "Клиент/Дело")
    let children = try await store.childFolders(of: parent!.id)
    #expect(children.map(\.relativePath) == ["Клиент/Дело/Иски"])

    await store.close()
    let db = try fixture.temp.rawConnection()
    #expect(try db.scalar("SELECT COUNT(*) FROM folders") as? Int64 == 4)
}

@Test("caseAt смотрит только на корень папки, caseContaining поднимается к предку")
func делоТочноВПапкеИПредок() async throws {
    let fixture = try await CatalogFixture.open()
    let store = fixture.store
    let rootId = fixture.root.id
    let parent = try await store.upsertCase(
        workspaceRootId: rootId, rootFolderPath: "Родитель", title: "Родительское"
    )
    #expect(try await store.caseAt(workspaceRootId: rootId, rootFolderPath: "Родитель")?.id == parent.id)
    #expect(try await store.caseAt(workspaceRootId: rootId, rootFolderPath: "Родитель/Вложенное") == nil)

    let nestedFolder = try await store.ensureFolder(
        workspaceRootId: rootId, relativePath: "Родитель/Вложенное"
    )
    #expect(try await store.caseContaining(folderId: nestedFolder.id)?.id == parent.id)

    await store.close()
}

@Test("Документ попадает в ближайшее дело; вложенное дело перекрывает родительское")
func ближайшееДелоИВложенность() async throws {
    let fixture = try await CatalogFixture.open()
    let store = fixture.store
    let rootId = fixture.root.id
    let modified = Date(timeIntervalSince1970: 1_725_000_000)

    let parentCase = try await store.upsertCase(
        workspaceRootId: rootId, rootFolderPath: "Родитель", title: "Родительское"
    )
    let nestedCase = try await store.upsertCase(
        workspaceRootId: rootId, rootFolderPath: "Родитель/Вложенное", title: "Вложенное"
    )

    let parentDoc = try await store.upsertWorkspaceDocument(
        workspaceRootId: rootId, relativePath: "Родитель/иск.docx",
        fileSize: 10, fileModifiedAt: modified, fileHash: "h-parent"
    )
    let nestedDoc = try await store.upsertWorkspaceDocument(
        workspaceRootId: rootId, relativePath: "Родитель/Вложенное/отзыв.docx",
        fileSize: 11, fileModifiedAt: modified, fileHash: "h-nested"
    )
    #expect(parentDoc.caseId == parentCase.id)
    #expect(nestedDoc.caseId == nestedCase.id)

    try await store.deleteCase(id: nestedCase.id)
    #expect(try await store.document(id: nestedDoc.id)?.caseId == parentCase.id)
    #expect(try await store.document(id: parentDoc.id)?.caseId == parentCase.id)

    let outsider = try await store.upsertWorkspaceDocument(
        workspaceRootId: rootId, relativePath: "Другое/письмо.docx",
        fileSize: 4, fileModifiedAt: modified, fileHash: nil
    )
    #expect(outsider.caseId == nil)

    let rebound = try await store.upsertCase(
        workspaceRootId: rootId, rootFolderPath: "Другое", title: "Новое дело"
    )
    #expect(try await store.document(id: outsider.id)?.caseId == rebound.id)

    let renamed = try await store.upsertCase(
        id: "ignored", workspaceRootId: rootId, rootFolderPath: "Другое", title: "Переименовано"
    )
    #expect(renamed.id == rebound.id)
    #expect(renamed.title == "Переименовано")
    #expect(try await store.document(id: outsider.id)?.caseId == rebound.id)
}

@Test("Повторный upsert документа сохраняет id и rowid; moveDocument пересчитывает папку и дело")
func upsertИПеремещениеДокумента() async throws {
    let fixture = try await CatalogFixture.open()
    let store = fixture.store
    let rootId = fixture.root.id
    let modified = Date(timeIntervalSince1970: 1_725_000_000)

    let parentCase = try await store.upsertCase(
        workspaceRootId: rootId, rootFolderPath: "Дело", title: "Дело"
    )
    let first = try await store.upsertWorkspaceDocument(
        workspaceRootId: rootId, relativePath: "Дело/черновик.docx",
        fileSize: 100, fileModifiedAt: modified, fileHash: "hash-a"
    )
    let second = try await store.upsertWorkspaceDocument(
        workspaceRootId: rootId, relativePath: "Дело/черновик.docx",
        fileSize: 250, fileModifiedAt: modified.addingTimeInterval(60), fileHash: "hash-b"
    )
    #expect(second.id == first.id)
    #expect(second.rowid == first.rowid)
    #expect(second.fileSize == 250)
    #expect(second.fileHash == "hash-b")
    #expect(second.caseId == parentCase.id)

    try await store.upsertCase(
        workspaceRootId: rootId, rootFolderPath: "Архив", title: "Архив"
    )
    let moved = try await store.moveDocument(
        id: first.id, toWorkspaceRootId: rootId, relativePath: "Архив/итог.docx"
    )
    #expect(moved.id == first.id)
    #expect(moved.rowid == first.rowid)
    #expect(moved.fileName == "итог.docx")
    #expect(moved.relativePath == "Архив/итог.docx")
    #expect(moved.folderId == (try await store.folder(workspaceRootId: rootId, relativePath: "Архив"))?.id)
    #expect(moved.caseId != parentCase.id)
    #expect(try await store.document(workspaceRootId: rootId, relativePath: "Дело/черновик.docx") == nil)

    let copy = try await store.upsertWorkspaceDocument(
        workspaceRootId: rootId, relativePath: "Дело/копия.docx",
        fileSize: 250, fileModifiedAt: modified, fileHash: "hash-b"
    )
    let dupes = try await store.documents(fileHash: "hash-b")
    #expect(Set(dupes.map(\.id)) == [moved.id, copy.id])

    let external = try await store.upsertExternalDocument(
        absolutePath: "/tmp/внешний.pdf/",
        fileSize: 8, fileModifiedAt: modified, fileHash: "hash-ext"
    )
    #expect(external.workspaceRootId == nil)
    #expect(external.caseId == nil)
    #expect(external.absolutePath == "/tmp/внешний.pdf")
    #expect(try await store.documents(in: .externalOnly).map(\.id) == [external.id])
    #expect(try await store.documents(in: .folderPath(workspaceRootId: rootId, relativePath: "Дело", recursive: true))
        .allSatisfy { $0.id != external.id })

    let againExt = try await store.upsertExternalDocument(
        absolutePath: "/tmp/внешний.pdf",
        fileSize: 16, fileModifiedAt: modified, fileHash: "hash-ext-2"
    )
    #expect(againExt.id == external.id)
    #expect(againExt.rowid == external.rowid)
    #expect(againExt.fileSize == 16)

    let url = try await store.fileURL(for: moved)
    #expect(url?.path == "/Users/test/РАБОТА/Архив/итог.docx")

    await #expect(throws: DocumentIndexError.self) {
        try await store.moveDocument(id: copy.id, toWorkspaceRootId: rootId, relativePath: "Архив/итог.docx")
    }
}

@Test("documents_fts находит словоформу имени и цифры; после delete и move старой строки нет")
func поискПоИмениИОчисткаFTS() async throws {
    let fixture = try await CatalogFixture.open()
    let store = fixture.store
    let rootId = fixture.root.id
    let modified = Date(timeIntervalSince1970: 1_725_000_000)

    let named = try await store.upsertWorkspaceDocument(
        workspaceRootId: rootId, relativePath: "Дело/договор_поставки.docx",
        fileSize: 1, fileModifiedAt: modified, fileHash: nil
    )
    let numbered = try await store.upsertWorkspaceDocument(
        workspaceRootId: rootId, relativePath: "Дело/1.pdf",
        fileSize: 2, fileModifiedAt: modified, fileHash: nil
    )

    let byStem = try await store.searchDocumentsByName(
        query: "договоры", scope: .workspaceRoot(id: rootId)
    )
    #expect(byStem.map(\.id) == [named.id])

    let byDigits = try await store.searchDocumentsByName(
        query: "1.pdf", scope: .workspaceRoot(id: rootId)
    )
    #expect(byDigits.map(\.id) == [numbered.id])

    let moved = try await store.moveDocument(
        id: named.id, toWorkspaceRootId: rootId, relativePath: "Архив/решение.docx"
    )
    #expect(try ftsHits(fixture.temp, query: "договоры") == 0)
    #expect(try await store.searchDocumentsByName(query: "решение", scope: .everything).map(\.id) == [moved.id])
    #expect(try await store.document(id: named.id)?.rowid == named.rowid)

    try await store.deleteDocument(id: numbered.id)
    #expect(try ftsHits(fixture.temp, query: "1.pdf") == 0)
    #expect(try await store.document(id: numbered.id) == nil)
}

@Test("Поиск по имени в рекурсивной папке: плейсхолдеры CTE идут раньше MATCH и LIKE")
func поискПоИмениВРекурсивнойОбласти() async throws {
    let fixture = try await CatalogFixture.open()
    let store = fixture.store
    let rootId = fixture.root.id
    let modified = Date(timeIntervalSince1970: 1_725_000_000)

    let inside = try await store.upsertWorkspaceDocument(
        workspaceRootId: rootId, relativePath: "Дело/Иски/договор_аренды.docx",
        fileSize: 1, fileModifiedAt: modified, fileHash: nil
    )
    _ = try await store.upsertWorkspaceDocument(
        workspaceRootId: rootId, relativePath: "Другое/договор_подряда.docx",
        fileSize: 1, fileModifiedAt: modified, fileHash: nil
    )
    let numbered = try await store.upsertWorkspaceDocument(
        workspaceRootId: rootId, relativePath: "Дело/Иски/№ 7-к.pdf",
        fileSize: 1, fileModifiedAt: modified, fileHash: nil
    )

    let recursive = SearchScope.folderPath(workspaceRootId: rootId, relativePath: "Дело", recursive: true)
    #expect(try await store.searchDocumentsByName(query: "договор", scope: recursive).map(\.id) == [inside.id])
    #expect(try await store.searchDocumentsByName(query: "7-к", scope: recursive).map(\.id) == [numbered.id])
    #expect(try await store.searchDocumentsByName(query: "подряда", scope: recursive).isEmpty)
}

@Test("deleteDocument собирает осиротевший текст и сохраняет текст, на который ссылается копия")
func удалениеДокументаСобираетСиротскиеТексты() async throws {
    let fixture = try await CatalogFixture.open()
    let store = fixture.store
    let rootId = fixture.root.id
    let modified = Date(timeIntervalSince1970: 1_725_000_000)

    let uniqueDoc = try await store.upsertWorkspaceDocument(
        workspaceRootId: rootId, relativePath: "a.docx",
        fileSize: 1, fileModifiedAt: modified, fileHash: "file-a"
    )
    let sharedA = try await store.upsertWorkspaceDocument(
        workspaceRootId: rootId, relativePath: "b.docx",
        fileSize: 1, fileModifiedAt: modified, fileHash: "file-b"
    )
    let sharedB = try await store.upsertWorkspaceDocument(
        workspaceRootId: rootId, relativePath: "c.docx",
        fileSize: 1, fileModifiedAt: modified, fileHash: "file-b"
    )

    await store.close()
    let db = try fixture.temp.rawConnection(readonly: false)
    try db.execute("PRAGMA foreign_keys = ON")
    try RawFixtures.insertText(db, hash: "th-unique", content: "уникальный текст договора")
    try RawFixtures.insertVariant(db, documentId: uniqueDoc.id, textHash: "th-unique")
    try RawFixtures.insertText(db, hash: "th-shared", content: "общий текст копии")
    try RawFixtures.insertVariant(db, documentId: sharedA.id, textHash: "th-shared")
    try RawFixtures.insertVariant(db, documentId: sharedB.id, textHash: "th-shared")

    try await store.open()
    try await store.deleteDocument(id: uniqueDoc.id)
    #expect(try scalarCount(db, "SELECT COUNT(*) FROM texts WHERE text_hash = 'th-unique'") == 0)
    #expect(try scalarCount(db, "SELECT COUNT(*) FROM texts WHERE text_hash = 'th-shared'") == 1)

    try await store.deleteDocument(id: sharedA.id)
    #expect(try scalarCount(db, "SELECT COUNT(*) FROM texts WHERE text_hash = 'th-shared'") == 1)
    #expect(try await store.document(id: sharedB.id) != nil)
}

@Test("documents(in:) режет области папки, дела, корня и everything; план рекурсивной папки без SCAN d")
func областиДокументовИПланЗапроса() async throws {
    let fixture = try await CatalogFixture.open()
    let store = fixture.store
    let rootId = fixture.root.id
    let modified = Date(timeIntervalSince1970: 1_725_000_000)

    let theCase = try await store.upsertCase(
        workspaceRootId: rootId, rootFolderPath: "Дело", title: "Дело"
    )
    let inCase = try await store.upsertWorkspaceDocument(
        workspaceRootId: rootId, relativePath: "Дело/а.docx",
        fileSize: 1, fileModifiedAt: modified, fileHash: nil
    )
    let nested = try await store.upsertWorkspaceDocument(
        workspaceRootId: rootId, relativePath: "Дело/Иски/б.docx",
        fileSize: 1, fileModifiedAt: modified, fileHash: nil
    )
    let other = try await store.upsertWorkspaceDocument(
        workspaceRootId: rootId, relativePath: "Другое/в.docx",
        fileSize: 1, fileModifiedAt: modified, fileHash: nil
    )
    let external = try await store.upsertExternalDocument(
        absolutePath: "/tmp/г.pdf",
        fileSize: 1, fileModifiedAt: modified, fileHash: nil
    )

    func ids(_ scope: SearchScope) async throws -> Set<String> {
        Set(try await store.documents(in: scope).map(\.id))
    }

    #expect(try await ids(.folderPath(workspaceRootId: rootId, relativePath: "Дело", recursive: true)) == [inCase.id, nested.id])
    #expect(try await ids(.folderPath(workspaceRootId: rootId, relativePath: "Дело", recursive: false)) == [inCase.id])
    #expect(try await ids(.wholeCase(id: theCase.id)) == [inCase.id, nested.id])
    #expect(try await ids(.workspaceRoot(id: rootId)) == [inCase.id, nested.id, other.id])
    #expect(try await ids(.everything) == [inCase.id, nested.id, other.id, external.id])
    #expect(try await ids(.externalOnly) == [external.id])
    #expect(try await store.documentCount(in: .workspaceRoot(id: rootId)) == 3)

    let (sql, bindings) = DocumentIndexStore.catalogDocumentsSQL(
        scope: .folderPath(workspaceRootId: rootId, relativePath: "Дело", recursive: true)
    )
    let db = try fixture.temp.rawConnection()
    let plan = try queryPlan(db, sql, bindings)
    let fullScan = plan.contains { $0 == "SCAN d" || $0.hasPrefix("SCAN d ") || $0.hasPrefix("SCAN documents") }
    #expect(!fullScan, "план без полного просмотра documents: \(plan)")
}

@Test("Пересчёт дел на 2000 документах укладывается в мягкий порог")
func пересчётДелНаБольшомКаталоге() async throws {
    let temp = TemporaryDatabase()
    let store = try await temp.openWriter()
    let root = try await store.registerWorkspaceRoot(name: "РАБОТА", localPath: "/Users/test/perf")
    await store.close()

    let db = try temp.rawConnection(readonly: false)
    try db.execute("PRAGMA foreign_keys = ON")

    var folderPaths: [String] = []
    for index in 0..<20 {
        let casePath = String(format: "Дело%02d", index)
        folderPaths.append(casePath)
        try RawFixtures.insertCase(
            db, id: "case-\(index)", workspaceRootId: root.id, rootFolderPath: casePath, title: casePath
        )
        for nested in 0..<9 {
            let sub = "\(casePath)/п\(nested)"
            folderPaths.append(sub)
            try RawFixtures.ensureFolder(db, workspaceRootId: root.id, relativePath: sub)
        }
    }
    #expect(folderPaths.count == 200)

    var docIndex = 0
    for path in folderPaths {
        for _ in 0..<10 {
            try RawFixtures.insertWorkspaceDocument(
                db,
                id: "doc-\(docIndex)",
                workspaceRootId: root.id,
                relativePath: "\(path)/файл-\(docIndex).docx"
            )
            docIndex += 1
        }
    }
    #expect(docIndex == 2000)

    try await store.open()
    let started = ContinuousClock.now
    try await store.reassignCases(workspaceRootId: root.id)
    let elapsed = ContinuousClock.now - started
    #expect(elapsed < .seconds(2), "пересчёт занял \(elapsed)")

    let sample = try await store.document(workspaceRootId: root.id, relativePath: "Дело03/п2/файл-330.docx")
    #expect(sample?.caseId == "case-3")
}

private struct CatalogFixture {
    let temp: TemporaryDatabase
    let store: DocumentIndexStore
    let root: WorkspaceRootRecord

    static func open() async throws -> CatalogFixture {
        let temp = TemporaryDatabase()
        let store = try await temp.openWriter()
        let root = try await store.registerWorkspaceRoot(name: "РАБОТА", localPath: "/Users/test/РАБОТА")
        return CatalogFixture(temp: temp, store: store, root: root)
    }
}

private func ftsHits(_ temp: TemporaryDatabase, query: String) throws -> Int64 {
    let stems = RussianTextNormalizer.queryStems(from: query)
    let match = DocumentSearchQuery.matchExpression(stems: stems, mode: .allWords)
    let db = try temp.rawConnection()
    if match.isEmpty {
        let pattern = "%" + DocumentSearchQuery.escapeForLike(query.lowercased()) + "%"
        return try scalarCount(db, "SELECT COUNT(*) FROM documents WHERE file_name_lower LIKE ? ESCAPE '\\'", pattern)
    }
    return try scalarCount(db, "SELECT COUNT(*) FROM documents_fts WHERE documents_fts MATCH ?", match)
}

private func scalarCount(_ db: SQLite.Connection, _ sql: String, _ binding: Binding? = nil) throws -> Int64 {
    let value: Binding?
    if let binding {
        value = try db.scalar(sql, [binding])
    } else {
        value = try db.scalar(sql)
    }
    if let int64 = value as? Int64 { return int64 }
    if let int = value as? Int { return Int64(int) }
    return 0
}
