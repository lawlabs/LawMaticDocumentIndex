import Foundation
import SQLite
import Testing
@testable import LawMaticDocumentIndex

@Test("Прежние маркеры v2 объединяются без потери времени и больше не создаются")
func consolidateRemovalMarkers() async throws {
    let temp = TemporaryDatabase(); let store = try await temp.openWriter()
    let generation = try await store.indexGeneration()
    await store.close()
    let raw = try temp.rawConnection(readonly: false)
    try raw.run("CREATE TABLE import_exclusions(root_id TEXT, path TEXT)")
    try raw.run("INSERT INTO import_exclusions VALUES ('r','a'), ('r','b')")
    try raw.run("INSERT INTO index_removals VALUES ('r','a','2020-01-01T00:00:00Z')")
    try await store.open()
    #expect(try await store.indexGeneration() == generation)
    #expect(try raw.scalar("SELECT removed_at_iso FROM index_removals WHERE path='a'") as? String == "2020-01-01T00:00:00Z")
    #expect(try raw.scalar("SELECT removed_at_iso FROM index_removals WHERE path='b'") as? String != nil)
    #expect(try raw.scalar("SELECT count(*) FROM sqlite_master WHERE name='import_exclusions'") as? Int64 == 0)
    await store.close(); try await store.open()
    #expect(try raw.scalar("SELECT count(*) FROM index_removals") as? Int64 == 2)
    #expect(try raw.scalar("SELECT count(*) FROM sqlite_master WHERE name='import_exclusions'") as? Int64 == 0)
}

@Test("Отказ обновления маркеров v2 откатывает схему и допускает повтор")
func removalUpgradeRollback() async throws {
    let temp = TemporaryDatabase(); let store = try await temp.openWriter(); await store.close()
    let raw = try temp.rawConnection(readonly: false)
    try raw.run("UPDATE index_metadata SET value='3' WHERE key='finder_extension_version'")
    try raw.run("CREATE TABLE import_exclusions(wrong_root TEXT, path TEXT)")
    try raw.run("INSERT INTO import_exclusions VALUES ('r','keep')")
    await #expect(throws: (any Error).self) { try await store.open() }
    #expect(try raw.scalar("SELECT value FROM index_metadata WHERE key='finder_extension_version'") as? String == "3")
    #expect(try raw.scalar("SELECT count(*) FROM import_exclusions") as? Int64 == 1)
    try raw.run("ALTER TABLE import_exclusions RENAME COLUMN wrong_root TO root_id")
    try await store.open()
    #expect(try raw.scalar("SELECT count(*) FROM index_removals WHERE path='keep'") as? Int64 == 1)
}

@Test("UUID файла и process epoch проверяются внутри транзакции мутации")
func guardedMutationCannotReachNewIndex() async throws {
    let temp = TemporaryDatabase(); let store = try await temp.openWriter()
    let doc = try await store.upsertExternalDocument(absolutePath: temp.directoryURL.appendingPathComponent("keep.txt").path, fileSize: 1, fileModifiedAt: Date(), fileHash: nil)
    let generation = try #require(await store.indexGeneration())
    let lease = DocumentIndexWriterLease()
    let guardValue = DocumentIndexMutationGuard(indexGeneration: generation, epoch: lease.value, lease: lease)
    lease.invalidate()
    await #expect(throws: DocumentIndexError.staleWriterGeneration) { try await store.clearIndex(mutationGuard: guardValue) }
    #expect(try await store.document(id: doc.id) != nil)
    let wrongFile = DocumentIndexMutationGuard(indexGeneration: "different-file", epoch: lease.value, lease: lease)
    await #expect(throws: DocumentIndexError.staleWriterGeneration) { _ = try await store.removeDocuments(in: .everything, mutationGuard: wrongFile) }
    #expect(try await store.document(id: doc.id) != nil)
}

@Test("Перевод external в workspace сохраняет ID, текст, метаданные и ссылки")
func promoteExternalRetainsIdentity() async throws {
    let temp = TemporaryDatabase(); let store = try await temp.openWriter()
    let root = try await store.registerWorkspaceRoot(name: "Work", localPath: temp.directoryURL.path)
    let selected = try await store.ensureCase(workspaceRootId: root.id, rootFolderPath: "Case", title: "My title")
    let external = try await store.upsertExternalDocument(absolutePath: temp.directoryURL.appendingPathComponent("Other/a.txt").path, fileSize: 10, fileModifiedAt: Date(), fileHash: nil)
    _ = try await store.attachText(documentId: external.id, content: "Original")
    _ = try await store.upsertDocumentUserMetadata(.init(documentId: external.id, notes: "Keep", confidentiality: "restricted"))
    _ = try await store.attachDocument(documentId: external.id, toCase: selected.id)
    let moved = try await store.moveDocument(id: external.id, toWorkspaceRootId: root.id, relativePath: "Other/a.txt")
    #expect(moved.id == external.id)
    #expect(try await store.documentCount(in: .wholeCase(id: selected.id)) == 1)
    #expect(try await store.documentText(documentId: external.id, type: .original) == "Original")
    #expect(try await store.documentUserMetadata(documentId: external.id)?.notes == "Keep")
}

@Test("Read-only reader делает согласованную recovery-копию с committed WAL, не меняя источник")
func readOnlyRecoverySnapshotIncludesWAL() async throws {
    let temp = TemporaryDatabase(); let writer = try await temp.openWriter()
    let doc = try await writer.upsertExternalDocument(absolutePath: temp.directoryURL.appendingPathComponent("a.txt").path, fileSize: 1, fileModifiedAt: Date(), fileHash: nil)
    _ = try await writer.attachText(documentId: doc.id, content: "Кварцозавр WAL")
    let reader = try await temp.openReader()
    let target = temp.directoryURL.appendingPathComponent("recovery.sqlite")
    try await reader.createRecoverySnapshot(at: target)
    let info = try DocumentIndexSnapshot.inspect(target, options: .publishedExport)
    #expect(info.generation == (try await writer.indexGeneration()))
    let restored = DocumentIndexStore(databaseURL: target, mode: .readOnly)
    try await restored.open()
    #expect(try await restored.documentText(documentId: doc.id, type: .original) == "Кварцозавр WAL")
    await #expect(throws: DocumentIndexError.readOnly) { try await reader.clearIndex() }
    #expect(try await writer.documentCount(in: .everything) == 1)
    await restored.close(); await reader.close(); await writer.close()
}
