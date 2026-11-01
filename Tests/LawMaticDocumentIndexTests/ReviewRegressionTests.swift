import Foundation
import Testing
@testable import LawMaticDocumentIndex

@Test("Аддитивные списки сохраняют неизвестные идентификаторы, типы связей и параллельные правки")
func additiveListsPreserveUnmappedData() async throws {
    let temp = TemporaryDatabase()
    let store = try await temp.openWriter()
    let root = try await store.registerWorkspaceRoot(name: "Work", localPath: temp.directoryURL.path)
    let selected = try await store.ensureCase(workspaceRootId: root.id, rootFolderPath: "A", title: "User title")
    let source = try await store.upsertExternalDocument(absolutePath: "/tmp/source", fileSize: 1, fileModifiedAt: Date(), fileHash: nil)
    let target = try await store.upsertExternalDocument(absolutePath: "/tmp/target", fileSize: 1, fileModifiedAt: Date(), fileHash: nil)
    let raw = try temp.rawConnection(readonly: false)
    try raw.run("UPDATE documents SET id = 'opaque-source' WHERE id = ?", source.id)
    try raw.run("UPDATE documents SET id = 'opaque-target' WHERE id = ?", target.id)
    try await store.replaceDocumentRelations(caseId: selected.id, relations: [.init(id: "opaque-relation", caseId: selected.id,
        sourceDocumentId: "opaque-source", targetDocumentId: "opaque-target", relationType: "future-relation")])
    try await store.replaceCaseTags(caseId: selected.id, tags: [.init(id: "opaque-tag", caseId: selected.id, name: "Keep")])
    _ = try await store.upsertCaseListItem(.init(id: "opaque-fact", caseId: selected.id, kind: .fact, sortIndex: 7, title: "Other edit"))
    try await store.upsertCaseListItems(caseId: selected.id, items: [
        .init(id: "ai-fact", caseId: "", kind: .fact, title: "AI fact"),
        .init(id: "ai-evidence", caseId: "", kind: .evidence, title: "AI evidence")])
    #expect(try await store.caseTags(caseId: selected.id).map(\.id) == ["opaque-tag"])
    #expect(try await store.documentRelations(caseId: selected.id).first?.relationType == "future-relation")
    #expect(try await store.documentRelations(caseId: selected.id).first?.sourceDocumentId == "opaque-source")
    #expect(try await store.caseListItems(caseId: selected.id, kind: .fact).map(\.id) == ["opaque-fact", "ai-fact"])
    #expect(try await store.caseListItems(caseId: selected.id, kind: .fact).last?.sortIndex == 8)
    #expect(try await store.caseRecord(id: selected.id)?.title == "User title")
    // Force the second kind to fail, proving the first kind also rolls back.
    try raw.run("CREATE TRIGGER reject_ai_evidence BEFORE INSERT ON case_evidences WHEN NEW.id = 'rejected' BEGIN SELECT RAISE(ABORT, 'injected'); END")
    do {
        try await store.upsertCaseListItems(caseId: selected.id, items: [
            .init(id: "rollback-fact", caseId: "", kind: .fact, title: "Rollback"),
            .init(id: "rejected", caseId: "", kind: .evidence, title: "Reject")])
        Issue.record("injected failure accepted")
    } catch {}
    #expect(try await store.caseListItems(caseId: selected.id, kind: .fact).count == 2)
    await store.close()
}

@Test("Очистка A не отменяет B и запрещает поздний ingest даже нового документа в A")
func clearedCaseRejectsLateAtomicIngest() async throws {
    let temp = TemporaryDatabase()
    let store = try await temp.openWriter()
    let root = try await store.registerWorkspaceRoot(name: "Work", localPath: temp.directoryURL.path)
    let a = try await store.ensureCase(workspaceRootId: root.id, rootFolderPath: "A", title: "A")
    _ = try await store.ensureCase(workspaceRootId: root.id, rootFolderPath: "B", title: "B")
    let contextA = DocumentIndexCaseIngestContext(rootId: root.id, rootName: "Work", localPath: temp.directoryURL.path, casePath: "A", title: "A")
    let contextB = DocumentIndexCaseIngestContext(rootId: root.id, rootName: "Work", localPath: temp.directoryURL.path, casePath: "B", title: "B")
    let lease = DocumentIndexWriterLease()
    let guardValue = DocumentIndexMutationGuard(indexGeneration: try await store.indexGeneration()!, epoch: lease.value, lease: lease)
    let start = Date(timeIntervalSinceNow: -5)
    _ = try await store.clearCase(id: a.id)
    #expect(try await store.clearCase(id: a.id) == 0)
    do {
        _ = try await store.ingestCaseDocument(location: .workspace(rootId: root.id, relativePath: "A/unindexed.txt"), physicalRoot: contextA,
            caseContext: contextA, attachToCase: false, absolutePath: "/tmp/A/unindexed.txt", fileSize: 1, modifiedAt: Date(),
            fileHash: nil, content: nil, extraction: nil, startedAt: start, mutationGuard: guardValue)
        Issue.record("late catalogue resurrected cleared case")
    } catch {}
    #expect(try await store.caseAt(workspaceRootId: root.id, rootFolderPath: "A") == nil)
    #expect(try await store.document(workspaceRootId: root.id, relativePath: "A/unindexed.txt") == nil)
    _ = try await store.ingestCaseDocument(location: .workspace(rootId: root.id, relativePath: "B/valid.txt"), physicalRoot: contextB,
        caseContext: contextB, attachToCase: false, absolutePath: "/tmp/B/valid.txt", fileSize: 1, modifiedAt: Date(),
        fileHash: nil, content: "text", extraction: .init(documentId: "", status: .complete), startedAt: start, mutationGuard: guardValue)
    #expect(try await store.document(workspaceRootId: root.id, relativePath: "B/valid.txt") != nil)
    await store.close()
    try await store.open()
    #expect(try await store.metadata(DocumentIndexStore.caseClearKey(rootId: root.id, path: "A")) != nil)
    await store.close()
}

@Test("Ошибка ingest откатывает корень, дело и продвижение внешнего документа")
func atomicIngestRollsBackPreparatoryWrites() async throws {
    let temp = TemporaryDatabase()
    let store = try await temp.openWriter()
    let external = try await store.upsertExternalDocument(absolutePath: "/tmp/new/Case/source.txt", fileSize: 1, fileModifiedAt: Date(), fileHash: nil)
    let context = DocumentIndexCaseIngestContext(rootId: "new-root", rootName: "New", localPath: "/tmp/new", casePath: "Case", title: "Case")
    let lease = DocumentIndexWriterLease()
    let guardValue = DocumentIndexMutationGuard(indexGeneration: try await store.indexGeneration()!, epoch: lease.value, lease: lease)
    do {
        _ = try await store.ingestCaseDocument(location: .workspace(rootId: "new-root", relativePath: "Case/source.txt"), physicalRoot: context,
            caseContext: context, attachToCase: true, absolutePath: "/tmp/new/Case/source.txt", fileSize: 1, modifiedAt: Date(),
            fileHash: nil, content: "", extraction: .init(documentId: "", status: .complete), startedAt: Date(), mutationGuard: guardValue)
        Issue.record("invalid extraction accepted")
    } catch {}
    #expect(try await store.workspaceRoot(id: "new-root") == nil)
    #expect(try await store.caseAt(workspaceRootId: "new-root", rootFolderPath: "Case") == nil)
    #expect(try await store.document(id: external.id)?.locationKind == .external)
    #expect(try await store.document(id: external.id)?.absolutePath == "/tmp/new/Case/source.txt")
    #expect(try await store.workspaceRoot(localPath: "/tmp/new") == nil)
    lease.invalidate()
    await #expect(throws: DocumentIndexError.staleWriterGeneration) {
        _ = try await store.ingestCaseDocument(location: .external(absolutePath: "/tmp/stale"), physicalRoot: nil,
            caseContext: context, attachToCase: false, absolutePath: "/tmp/stale", fileSize: 1, modifiedAt: Date(),
            fileHash: nil, content: nil, extraction: nil, startedAt: Date(), mutationGuard: guardValue)
    }
    #expect(try await store.workspaceRoot(id: "new-root") == nil)
    await store.close()
}

@Test("Кэш возможностей переиспользуется и обновляется при изменении живого индекса")
func capabilitiesCacheTracksLiveChanges() async throws {
    let temp = TemporaryDatabase()
    let writer = try await temp.openWriter()
    let reader = DocumentIndexStore(databaseURL: temp.databaseURL, mode: .readOnly)
    try await reader.open()
    let baseline = await reader.capabilityReadCount
    for _ in 0..<10 { _ = try await reader.documentCount(in: .everything) }
    #expect(await reader.capabilityReadCount == baseline)
    try await writer.setMetadata(DocumentIndexSchema.MetadataKey.readerRequiredFeatures, "[\"future_feature\"]")
    do { _ = try await reader.documentCount(in: .everything); Issue.record("live reader accepted unknown feature") } catch {}
    do { _ = try await writer.readerCapabilities(); Issue.record("writer cache ignored own change") } catch {}
    try await writer.setMetadata(DocumentIndexSchema.MetadataKey.readerRequiredFeatures, "[\"explicit_case_documents\"]")
    #expect(try await reader.readerCapabilities().supportsExplicitCaseDocuments)
    #expect(await reader.capabilityReadCount == baseline + 1)
    await reader.close(); await writer.close()
}
