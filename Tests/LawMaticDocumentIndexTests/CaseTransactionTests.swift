import Foundation
import Testing
@testable import LawMaticDocumentIndex

@Test("ensureCase не меняет пользовательское имя при повторном извлечении")
func ensureCasePreservesTitle() async throws {
    let temp = TemporaryDatabase()
    let store = try await temp.openWriter()
    let root = try await store.registerWorkspaceRoot(name: "Работа", localPath: temp.directoryURL.path)
    let first = try await store.ensureCase(workspaceRootId: root.id, rootFolderPath: "Client/Case", title: "Пользовательское имя")
    let second = try await store.ensureCase(workspaceRootId: root.id, rootFolderPath: "Client/Case", title: "Case")
    #expect(first.id == second.id)
    #expect(second.title == "Пользовательское имя")
    await store.close()
}

@Test("Полный снимок дела откатывает карточку, название, списки и теги при отказе связи")
func caseSnapshotIsAtomic() async throws {
    let temp = TemporaryDatabase()
    let store = try await temp.openWriter()
    let root = try await store.registerWorkspaceRoot(name: "Работа", localPath: temp.directoryURL.path)
    let initial = try await store.saveCaseSnapshot(workspaceRootId: root.id, rootFolderPath: "Case", title: "Прежнее имя",
        card: .init(caseId: "", caseDescription: "Прежнее описание"),
        items: [.init(id: "old-fact", caseId: "", kind: .fact, title: "Прежний факт")],
        tags: [.init(id: "old-tag", caseId: "", name: "Прежний тег")], relations: [])
    do {
        _ = try await store.saveCaseSnapshot(workspaceRootId: root.id, rootFolderPath: "Case", title: "Новое имя",
            card: .init(caseId: "", caseDescription: "Новое описание"),
            items: [.init(id: "new-fact", caseId: "", kind: .fact, title: "Новый факт")],
            tags: [.init(id: "new-tag", caseId: "", name: "Новый тег")],
            relations: [.init(caseId: "", sourceDocumentId: "missing", targetDocumentId: "also-missing", relationType: "related")])
        Issue.record("invalid relation was accepted")
    } catch {}
    #expect(try await store.caseRecord(id: initial.id)?.title == "Прежнее имя")
    #expect(try await store.caseCard(caseId: initial.id)?.caseDescription == "Прежнее описание")
    #expect(try await store.caseListItems(caseId: initial.id, kind: .fact).map(\.id) == ["old-fact"])
    #expect(try await store.caseTags(caseId: initial.id).map(\.id) == ["old-tag"])
    await store.close()
}

@Test("Сбой карты откатывает новый обезличенный текст и сохраняет прежний проверенный запуск")
func anonymizationSaveIsAtomic() async throws {
    let temp = TemporaryDatabase()
    let store = try await temp.openWriter()
    let root = try await store.registerWorkspaceRoot(name: "Работа", localPath: temp.directoryURL.path)
    let document = try await store.upsertWorkspaceDocument(workspaceRootId: root.id, relativePath: "contract.txt",
        fileSize: 10, fileModifiedAt: Date(), fileHash: "file")
    let source = try await store.attachText(documentId: document.id, content: "Иванов подписал договор")
    let first = try await store.saveAnonymization(content: "[ФИО 1] подписал договор",
        run: .init(documentId: document.id, status: "reviewed", rulesJSON: "old-hashes"),
        entities: [.init(id: "person", runId: "", entityType: "person", originalValue: "Иванов", replacementValue: "[ФИО 1]")],
        occurrences: [], expectedSourceTextHash: source.variant.textHash)
    do {
        _ = try await store.saveAnonymization(content: "НОВАЯ КОПИЯ",
            run: .init(documentId: document.id, status: "needs_review", rulesJSON: "new-hashes"),
            entities: [.init(id: "person", runId: "", caseId: "missing-case", entityType: "person", originalValue: "Иванов", replacementValue: "NEW")],
            occurrences: [], expectedSourceTextHash: source.variant.textHash)
        Issue.record("invalid mapping was accepted")
    } catch {}
    #expect(try await store.documentText(documentId: document.id, type: .anonymized) == "[ФИО 1] подписал договор")
    let latest = try await store.latestAnonymizationRun(documentId: document.id)
    #expect(latest?.0.id == first.id)
    #expect(latest?.0.status == "reviewed")
    #expect(latest?.0.rulesJSON == "old-hashes")
    #expect(latest?.1.first?.replacementValue == "[ФИО 1]")
    await #expect(throws: DocumentIndexError.invalidArgument("Исходный текст изменился. Подготовьте обезличенную копию заново.")) {
        _ = try await store.saveAnonymization(content: "STALE", run: .init(documentId: document.id, status: "needs_review"),
            entities: [], occurrences: [], expectedSourceTextHash: "old-source")
    }
    #expect(try await store.documentText(documentId: document.id, type: .anonymized) == "[ФИО 1] подписал договор")
    await store.close()
}

@Test("Очистка дела удаляет его карточку и документы, сохраняя самостоятельное вложенное дело")
func clearCasePreservesNestedCase() async throws {
    let temp = TemporaryDatabase()
    let store = try await temp.openWriter()
    let root = try await store.registerWorkspaceRoot(name: "Работа", localPath: temp.directoryURL.path)
    let parent = try await store.saveCaseCard(workspaceRootId: root.id, rootFolderPath: "Case", title: "Parent", card: .init(caseId: "", caseDescription: "Card"))
    let child = try await store.ensureCase(workspaceRootId: root.id, rootFolderPath: "Case/Child", title: "Child")
    let one = try await store.upsertWorkspaceDocument(workspaceRootId: root.id, relativePath: "Case/a.txt", fileSize: 1, fileModifiedAt: Date(), fileHash: nil)
    let two = try await store.upsertWorkspaceDocument(workspaceRootId: root.id, relativePath: "Case/Child/b.txt", fileSize: 1, fileModifiedAt: Date(), fileHash: nil)
    _ = try await store.upsertCaseListItem(.init(caseId: parent.id, kind: .fact, title: "Fact"))
    #expect(try await store.clearCase(id: parent.id) == 1)
    #expect(try await store.caseRecord(id: parent.id) == nil)
    #expect(try await store.caseCard(caseId: parent.id) == nil)
    #expect(try await store.caseListItems(caseId: parent.id, kind: .fact).isEmpty)
    #expect(try await store.document(id: one.id) == nil)
    #expect(try await store.caseRecord(id: child.id)?.title == "Child")
    #expect(try await store.document(id: two.id)?.caseId == child.id)
    #expect(try await store.integrityCheck().isEmpty)
    await store.close()
}
