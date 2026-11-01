import Foundation
import SQLite
import Testing
@testable import LawMaticDocumentIndex

@Test("Один root ID переносится между компьютерами без записи локального пути в базу")
func rootRebinding() async throws {
    let temp = TemporaryDatabase(); let writer = try await temp.openWriter()
    let root = try await writer.registerWorkspaceRoot(id: "shared", name: "Work", localPath: "/Users/a/Work")
    _ = try await writer.registerWorkspaceRoot(id: root.id, name: "Work", localPath: "/Volumes/Work")
    let doc = try await writer.upsertWorkspaceDocument(workspaceRootId: root.id, relativePath: "case/a.txt", fileSize: 1, fileModifiedAt: Date(), fileHash: "hash")
    _ = try await writer.attachText(documentId: doc.id, content: "Исковое заявление")
    #expect(try await writer.fileURL(for: doc)?.path == "/Volumes/Work/case/a.txt")
    let reader = try await temp.openReader()
    #expect(try await reader.fileURL(for: doc) == nil)
    try await reader.setWorkspacePaths([root.id: "/Users/b/Documents"])
    #expect(try await reader.fileURL(for: doc)?.path == "/Users/b/Documents/case/a.txt")
    let hits = try await reader.searchChunksKeyword(query: "иск", scope: .everything)
    #expect(hits.hits.first?.fileURL.path == "/Users/b/Documents/case/a.txt")
    let db = try temp.rawConnection()
    #expect(try db.scalar("SELECT local_path FROM workspace_roots") as? String == "")
}

@Test("Неудачное переизвлечение скрывает старый текст и его векторы, сохраняя историю")
func staleTextInvalidation() async throws {
    let env = try await LifecycleEnv()
    try await env.store.storeExtraction(documentId: env.doc.id, content: "Старое обязательство", state: .init(documentId: env.doc.id, status: .complete), sourceFileHash: "one")
    _ = try await env.store.upsertWorkspaceDocument(workspaceRootId: env.root.id, relativePath: "case/a.txt", fileSize: 2, fileModifiedAt: Date(), fileHash: "two")
    try await env.store.storeExtraction(documentId: env.doc.id, content: "", state: .init(documentId: env.doc.id, status: .failed), sourceFileHash: "two")
    #expect(try await env.store.searchChunksKeyword(query: "обязательство", scope: .everything).hits.isEmpty)
    #expect(try await env.store.textVariants(documentId: env.doc.id).first?.isCurrent == false)
    #expect(try await env.store.chunkCount(in: .everything) == 0)
}

@Test("Несогласованный результат извлечения откатывается целиком")
func extractionRollback() async throws {
    let env = try await LifecycleEnv()
    await #expect(throws: DocumentIndexError.self) {
        try await env.store.storeExtraction(documentId: env.doc.id, content: "Договор", state: .init(documentId: env.doc.id, status: .complete), pages: [.init(pageNumber: 1, utf16Start: 0, utf16End: 999)], sourceFileHash: "one")
    }
    #expect(try await env.store.textVariants(documentId: env.doc.id).isEmpty)
    #expect(try await env.store.chunkCount(in: .everything) == 0)
    await #expect(throws: DocumentIndexError.self) {
        try await env.store.storeExtraction(documentId: env.doc.id, content: "Договор", state: .init(documentId: env.doc.id, status: .complete, pagesTotal: 5, pagesProcessed: 2), sourceFileHash: "one")
    }
}

@Test("Имена копий не переносятся между областями, копии не повышают RRF")
func copiedNameIsolation() async throws {
    let env = try await LifecycleEnv()
    let copy = try await env.store.upsertWorkspaceDocument(workspaceRootId: env.root.id, relativePath: "other/кварцозавр.txt", fileSize: 1, fileModifiedAt: Date(), fileHash: nil)
    for doc in [env.doc, copy] { _ = try await env.store.attachText(documentId: doc.id, content: "Обычное сопроводительное письмо") }
    let scoped = try await env.store.searchChunksKeyword(query: "кварцозавр", scope: .folderPath(workspaceRootId: env.root.id, relativePath: "case", recursive: true))
    #expect(scoped.hits.isEmpty)
    let hits = try await env.store.searchChunksKeyword(query: "письмо", scope: .everything).hits
    let unique = ReciprocalRankFusion.merge(lexical: [hits[0]], semantic: [], limit: 10)
    let copies = ReciprocalRankFusion.merge(lexical: hits, semantic: [], limit: 10)
    #expect(unique.first?.score == copies.first?.score)
}

@Test("Подстрочное совпадение возвращает реальный фрагмент в конце документа")
func substringContext() async throws {
    let env = try await LifecycleEnv()
    _ = try await env.store.attachText(documentId: env.doc.id, content: Array(repeating: "абзац", count: 500).joined(separator: " ") + " zzzUNIQUECODEzzz")
    let result = try await env.store.searchChunksKeyword(query: "UNIQUECODE", scope: .everything)
    #expect(result.hits.first?.content.contains("UNIQUECODE") == true)
    #expect((result.hits.first?.utf16Start ?? 0) > 0)
}

@Test("Объединение папок применяется до поиска, .. не выходит из корня")
func unionScope() async throws {
    let env = try await LifecycleEnv()
    for path in ["case/a.txt", "other/b.txt", "excluded/c.txt"] {
        let doc = try await env.store.upsertWorkspaceDocument(workspaceRootId: env.root.id, relativePath: path, fileSize: 1, fileModifiedAt: Date(), fileHash: nil)
        _ = try await env.store.attachText(documentId: doc.id, content: "Общий договор поставки " + path)
    }
    let scope = SearchScope.union([.folderPath(workspaceRootId: env.root.id, relativePath: "case", recursive: true), .union([.folderPath(workspaceRootId: env.root.id, relativePath: "other", recursive: true)])])
    #expect(try await env.store.searchChunksKeyword(query: "договор", scope: scope).hits.count == 2)
    await #expect(throws: DocumentIndexError.self) {
        _ = try await env.store.upsertWorkspaceDocument(workspaceRootId: env.root.id, relativePath: "../outside.txt", fileSize: 1, fileModifiedAt: Date(), fileHash: nil)
    }
}

@Test("Удаление блокирует повторный импорт, снимок включает WAL и читается независимо")
func deleteAndSnapshot() async throws {
    let env = try await LifecycleEnv()
    _ = try await env.store.attachText(documentId: env.doc.id, content: "Договор поставки")
    let snapshot = env.temp.directoryURL.appendingPathComponent("snapshot.sqlite")
    try await env.store.exportSnapshot(to: snapshot)
    let reader = DocumentIndexStore(databaseURL: snapshot, mode: .readOnly)
    try await reader.open()
    #expect(try await reader.searchChunksKeyword(query: "договор", scope: .everything).hits.count == 1)
    _ = try await env.store.removeDocuments(in: .documents(ids: [env.doc.id]))
    #expect(try await env.store.searchChunksKeyword(query: "договор", scope: .everything).hits.isEmpty)
    #expect(try await reader.searchChunksKeyword(query: "договор", scope: .everything).hits.count == 1)
}

private final class LifecycleEnv {
    let temp = TemporaryDatabase()
    let store: DocumentIndexStore
    let root: WorkspaceRootRecord
    let doc: IndexedDocument
    init() async throws {
        store = try await temp.openWriter()
        root = try await store.registerWorkspaceRoot(id: "root", name: "Work", localPath: "/tmp/lifecycle")
        doc = try await store.upsertWorkspaceDocument(workspaceRootId: root.id, relativePath: "case/a.txt", fileSize: 1, fileModifiedAt: Date(), fileHash: "one")
    }
}

@Test("Whole ingest rolls back catalogue, hash, text and state together")
func atomicFileIngest() async throws {
    let env = try await LifecycleEnv()
    let location = IndexedFileLocation.workspace(rootId: env.root.id, relativePath: "case/a.txt")
    _ = try await env.store.ingestFile(location: location, fileSize: 1, modifiedAt: Date(), fileHash: "one",
        content: "Исходный договор", extraction: .init(documentId: "", status: .complete))
    await #expect(throws: DocumentIndexError.self) {
        _ = try await env.store.ingestFile(location: location, fileSize: 2, modifiedAt: Date(), fileHash: "two",
            content: "Изменение", extraction: .init(documentId: "", status: .complete),
            pages: [.init(pageNumber: 1, utf16Start: 0, utf16End: 1000)])
    }
    #expect(try await env.store.document(id: env.doc.id)?.fileHash == "one")
    #expect(try await env.store.extractionState(documentId: env.doc.id)?.attempts == 1)
    #expect(try await env.store.searchChunksKeyword(query: "исходный", scope: .everything).hits.count == 1)
    await #expect(throws: DocumentIndexError.self) {
        _ = try await env.store.ingestFile(location: .workspace(rootId: env.root.id, relativePath: "new.txt"),
            fileSize: 2, modifiedAt: Date(), fileHash: "two", content: "",
            extraction: .init(documentId: "", status: .complete))
    }
    #expect(try await env.store.document(workspaceRootId: env.root.id, relativePath: "new.txt") == nil)
}

@Test("Folder move preserves case and document identities and text, including external conversion")
func folderMovePreservesIdentity() async throws {
    let env = try await LifecycleEnv()
    let caseRecord = try await env.store.upsertCase(workspaceRootId: env.root.id, rootFolderPath: "case", title: "Дело")
    let nested = try await env.store.upsertCase(workspaceRootId: env.root.id, rootFolderPath: "case/child", title: "Вложенное")
    let child = try await env.store.upsertWorkspaceDocument(workspaceRootId: env.root.id, relativePath: "case/child/b.txt", fileSize: 1, fileModifiedAt: Date(), fileHash: nil)
    _ = try await env.store.attachText(documentId: child.id, content: "Вложенный договор")
    try await env.store.moveFolder(workspaceRootId: env.root.id, relativePath: "case", toRootId: env.root.id, destinationPath: "renamed")
    #expect(try await env.store.document(id: env.doc.id)?.relativePath == "renamed/a.txt")
    #expect(try await env.store.document(id: env.doc.id)?.caseId == caseRecord.id)
    #expect(try await env.store.document(id: child.id)?.caseId == nested.id)
    #expect(try await env.store.searchChunksKeyword(query: "договор", scope: .wholeCase(id: nested.id)).hits.count == 1)
    #expect(try await env.store.documentCount(in: .folderPath(workspaceRootId: env.root.id, relativePath: "case", recursive: true)) == 0)
    try await env.store.moveToExternal(documentId: child.id, absolutePath: "/tmp/exported.txt")
    #expect(try await env.store.searchChunksKeyword(query: "договор", scope: .externalOnly).hits.first?.documentId == child.id)
    #expect(try await env.store.document(id: child.id)?.caseId == nil)
}

@Test("An extraction started before explicit removal cannot resurrect a deleted index entry")
func delayedExtractionAfterRemoval() async throws {
    let env = try await LifecycleEnv()
    let started = Date(timeIntervalSinceNow: -60)
    _ = try await env.store.removeDocuments(in: .documents(ids: [env.doc.id]))
    await #expect(throws: DocumentIndexError.self) {
        _ = try await env.store.ingestFile(location: .workspace(rootId: env.root.id, relativePath: "case/a.txt"),
            fileSize: 1, modifiedAt: Date(), fileHash: "one", content: "Запоздавший договор",
            extraction: .init(documentId: "", status: .complete), extractionStartedAt: started)
    }
    #expect(try await env.store.documentCount(in: .everything) == 0)
    _ = try await env.store.ingestFile(location: .workspace(rootId: env.root.id, relativePath: "case/a.txt"),
        fileSize: 1, modifiedAt: Date(), fileHash: "one", content: "Повторное добавление",
        extraction: .init(documentId: "", status: .complete), extractionStartedAt: Date(timeIntervalSinceNow: 1))
    #expect(try await env.store.documentCount(in: .everything) == 1)
}
