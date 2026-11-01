import Foundation
import Testing
@testable import LawMaticDocumentIndex

private extension DocumentIndexStore {
    func testForeignKeysEnabled() throws -> Bool { try Self.pragmaInt64(db(), "foreign_keys") == 1 }
}

@Test("Вложения входят в дело ровно один раз, сохраняют ID/метаданные и переживают очистку другого дела")
func explicitCaseDocumentsLifecycle() async throws {
    let temp = TemporaryDatabase()
    let store = try await temp.openWriter()
    let root = try await store.registerWorkspaceRoot(name: "Work", localPath: temp.directoryURL.path)
    let a = try await store.ensureCase(workspaceRootId: root.id, rootFolderPath: "A", title: "A")
    let b = try await store.ensureCase(workspaceRootId: root.id, rootFolderPath: "B", title: "B")
    let workspace = try await store.upsertWorkspaceDocument(workspaceRootId: root.id, relativePath: "A/shared.txt", fileSize: 10, fileModifiedAt: Date(), fileHash: "w")
    let external = try await store.upsertExternalDocument(absolutePath: temp.directoryURL.appendingPathComponent("external.txt").path, fileSize: 10, fileModifiedAt: Date(), fileHash: "e")
    _ = try await store.attachText(documentId: workspace.id, content: "Кварцозавр рабочий файл")
    _ = try await store.attachText(documentId: external.id, content: "Кварцозавр внешний файл")
    _ = try await store.upsertDocumentUserMetadata(.init(documentId: external.id, notes: "Protected", confidentiality: "restricted"))
    let first = try await store.attachDocument(documentId: external.id, toCase: a.id)
    #expect(try await store.attachDocument(documentId: external.id, toCase: a.id) == first)
    _ = try await store.attachDocument(documentId: workspace.id, toCase: a.id) // Both automatic and explicit: no duplicate.
    _ = try await store.attachDocument(documentId: external.id, toCase: b.id)
    _ = try await store.attachDocument(documentId: workspace.id, toCase: b.id)
    #expect(try await store.document(id: external.id)?.caseId == nil)
    #expect(try await store.documents(in: .wholeCase(id: a.id)).count == 2)
    #expect(try await store.documentCount(in: .wholeCase(id: b.id)) == 2)
    #expect(try await store.documents(in: .folderPath(workspaceRootId: root.id, relativePath: "B", recursive: true)).isEmpty)
    let hits = try await store.searchChunksKeyword(query: "кварцозавр", scope: .wholeCase(id: b.id), limit: 10)
    #expect(Set(hits.hits.map(\.documentId)) == [workspace.id, external.id])
    #expect(try await store.chunkCount(in: .wholeCase(id: b.id)) == 2)
    await store.close()
    try await store.open()
    #expect(try await store.caseDocumentLinks(caseId: a.id).first == first)
    #expect(try await store.documentUserMetadata(documentId: external.id)?.confidentiality == "restricted")
    #expect(try await store.clearCase(id: a.id) == 0) // Shared workspace file must also remain for B.
    #expect(try await store.documentCount(in: .wholeCase(id: b.id)) == 2)
    #expect(try await store.documentCaseLinks(documentId: external.id).map(\.caseId) == [b.id])
    _ = try await store.removeDocuments(in: .documents(ids: [workspace.id]))
    #expect(try await store.documentCaseLinks(documentId: workspace.id).isEmpty)
    try await store.deleteCase(id: b.id)
    #expect(try await store.documentCaseLinks(documentId: external.id).isEmpty)
    #expect(try await store.document(id: external.id) != nil)
    #expect(try await store.integrityCheck().isEmpty)
    #expect(try await store.testForeignKeysEnabled())
    await store.close()
    let raw = try temp.rawConnection()
    var issues = 0
    for _ in try raw.prepare("PRAGMA foreign_key_check") { issues += 1 }
    #expect(issues == 0)
}

@Test("Reader прежней v2 без связей не обращается к отсутствующей таблице; writer сохраняет поколение при обновлении")
func olderV2ReaderWithoutLinks() async throws {
    let temp = TemporaryDatabase()
    let store = try await temp.openWriter()
    let root = try await store.registerWorkspaceRoot(name: "Work", localPath: temp.directoryURL.path)
    let c = try await store.ensureCase(workspaceRootId: root.id, rootFolderPath: "A", title: "Custom")
    let doc = try await store.upsertWorkspaceDocument(workspaceRootId: root.id, relativePath: "A/a.txt", fileSize: 1, fileModifiedAt: Date(), fileHash: "f")
    _ = try await store.attachText(documentId: doc.id, content: "Кварцозавр")
    let generation = try await store.indexGeneration()
    await store.close()
    let raw = try temp.rawConnection(readonly: false)
    try raw.run("DROP TABLE case_document_links")
    try raw.run("DELETE FROM index_metadata WHERE key = ?", DocumentIndexSchema.MetadataKey.readerRequiredFeatures)
    try raw.run("UPDATE index_metadata SET value = '3' WHERE key = ?", DocumentIndexSchema.MetadataKey.finderExtensionVersion)
    let reader = DocumentIndexStore(databaseURL: temp.databaseURL, mode: .readOnly)
    try await reader.open()
    #expect(try await reader.testForeignKeysEnabled())
    #expect(try await reader.readerCapabilities().supportsExplicitCaseDocuments == false)
    #expect(try await reader.documents(in: .wholeCase(id: c.id)).map(\.id) == [doc.id])
    #expect(try await reader.searchChunksKeyword(query: "кварцозавр", scope: .wholeCase(id: c.id)).hits.count == 1)
    #expect(try await reader.caseDocumentLinks(caseId: c.id).isEmpty)
    await reader.close()
    try await store.open()
    #expect(try await store.readerCapabilities().supportsExplicitCaseDocuments)
    #expect(try await store.indexGeneration() == generation)
    #expect(try await store.caseRecord(id: c.id)?.title == "Custom")
    await store.close()
}

@Test("Неизвестные возможности отвергаются reader и writer без затирания metadata")
func unknownReaderFeatureRejected() async throws {
    let temp = TemporaryDatabase()
    let store = try await temp.openWriter()
    await store.close()
    let raw = try temp.rawConnection(readonly: false)
    try raw.run("UPDATE index_metadata SET value = ? WHERE key = ?", "[\"future_feature\"]", DocumentIndexSchema.MetadataKey.readerRequiredFeatures)
    for mode in [DocumentIndexOpenMode.readOnly, .readWrite] {
        let candidate = DocumentIndexStore(databaseURL: temp.databaseURL, mode: mode)
        do { try await candidate.open(); Issue.record("unknown feature accepted") } catch {}
    }
    #expect(try raw.scalar("SELECT value FROM index_metadata WHERE key = ?", DocumentIndexSchema.MetadataKey.readerRequiredFeatures) as? String == "[\"future_feature\"]")
    try raw.run("UPDATE index_metadata SET value = '[]' WHERE key = ?", DocumentIndexSchema.MetadataKey.readerRequiredFeatures)
    try raw.run("UPDATE index_metadata SET value = '999' WHERE key = ?", DocumentIndexSchema.MetadataKey.finderExtensionVersion)
    do { try await store.open(); Issue.record("future extension downgraded") } catch {}
    #expect(try raw.scalar("SELECT value FROM index_metadata WHERE key = ?", DocumentIndexSchema.MetadataKey.finderExtensionVersion) as? String == "999")
}
