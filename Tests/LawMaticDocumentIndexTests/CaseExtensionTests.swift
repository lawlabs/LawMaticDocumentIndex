import Foundation
import Testing
@testable import LawMaticDocumentIndex

@Test("Расширения Finder создаются рядом с ядром, user_version контракта не меняется")
func расширенияFinderВТойЖеБазе() async throws {
    let temp = TemporaryDatabase()
    let store = try await temp.openWriter()
    #expect(try await store.metadata(DocumentIndexSchema.MetadataKey.finderExtensionVersion) == String(DocumentIndexSchema.finderExtensionVersion))
    await store.close()

    let db = try temp.rawConnection()
    var tables: Set<String> = []
    for row in try db.prepare("SELECT name FROM sqlite_master WHERE type = 'table'") {
        if let name = row[0] as? String { tables.insert(name) }
    }
    for table in DocumentIndexSchema.extensionTables {
        #expect(tables.contains(table), "таблица \(table) должна существовать")
    }
    #expect(try pragmaValue(db, "user_version") == Int64(DocumentIndexSchema.userVersion))
}

@Test("Карточка и списки дела пишутся точечно и удаляются каскадом вместе с делом")
func карточкаИСпискиКаскадом() async throws {
    let fixture = try await ExtensionFixture.open()
    let store = fixture.store
    let theCase = try await store.upsertCase(
        workspaceRootId: fixture.root.id, rootFolderPath: "Дело", title: "ООО Тест"
    )

    let card = try await store.upsertCaseCard(
        CaseCardRecord(caseId: theCase.id, caseNumber: "А40-1", caseDescription: "поставка")
    )
    #expect(card.caseNumber == "А40-1")
    #expect(try await store.caseCard(caseId: theCase.id)?.caseDescription == "поставка")

    let fact = try await store.upsertCaseListItem(
        CaseListItemRecord(
            caseId: theCase.id,
            kind: .fact,
            sortIndex: 1,
            title: "Оплата",
            body: "не было",
            payloadJSON: #"{"title":"Оплата"}"#
        )
    )
    #expect(!fact.id.isEmpty)
    #expect(try await store.caseListItems(caseId: theCase.id, kind: .fact).map(\.title) == ["Оплата"])

    _ = try await store.upsertCaseTag(CaseTagRecord(caseId: theCase.id, name: "договор"))
    #expect(try await store.caseTags(caseId: theCase.id).map(\.name) == ["договор"])

    await #expect(throws: DocumentIndexError.invalidArgument("пустой заголовок записи дела")) {
        try await store.upsertCaseListItem(
            CaseListItemRecord(caseId: theCase.id, kind: .evidence, title: "  ")
        )
    }
    await #expect(throws: DocumentIndexError.notFound("дело missing")) {
        try await store.upsertCaseCard(CaseCardRecord(caseId: "missing"))
    }

    try await store.deleteCaseListItem(kind: .fact, id: fact.id)
    #expect(try await store.caseListItems(caseId: theCase.id, kind: .fact).isEmpty)

    let task = try await store.upsertCaseListItem(
        CaseListItemRecord(caseId: theCase.id, kind: .lawyerTask, title: "Запросить акт")
    )
    try await store.deleteCase(id: theCase.id)
    #expect(try await store.caseCard(caseId: theCase.id) == nil)
    #expect(try await store.caseListItems(caseId: theCase.id, kind: .lawyerTask).isEmpty)
    await #expect(throws: DocumentIndexError.notFound("запись \(task.id)")) {
        try await store.deleteCaseListItem(kind: .lawyerTask, id: task.id)
    }

    await store.close()
}

@Test("Метаданные документа и запуск анонимизации привязаны к каталогу v2")
func метаданныеДокументаИАнонимизация() async throws {
    let fixture = try await ExtensionFixture.open()
    let store = fixture.store
    let theCase = try await store.upsertCase(
        workspaceRootId: fixture.root.id, rootFolderPath: "Дело", title: "Дело"
    )
    let document = try await store.upsertWorkspaceDocument(
        workspaceRootId: fixture.root.id,
        relativePath: "Дело/договор.pdf",
        fileSize: 10,
        fileModifiedAt: Date(timeIntervalSince1970: 1_725_000_000),
        fileHash: "abc"
    )

    let meta = try await store.upsertDocumentUserMetadata(
        DocumentUserMetadataRecord(
            documentId: document.id,
            notes: "важно",
            confidentiality: "restricted",
            isEvidence: true
        )
    )
    #expect(meta.notes == "важно")
    #expect(try await store.documentUserMetadata(documentId: document.id)?.isEvidence == true)

    let (run, entities) = try await store.upsertAnonymizationRun(
        AnonymizationRunRecord(documentId: document.id, caseId: theCase.id, status: "current", method: "rules"),
        entities: [
            AnonymizationEntityRecord(
                runId: "",
                entityType: "person",
                originalValue: "Иванов",
                replacementValue: "Сторона1"
            )
        ]
    )
    #expect(run.status == "current")
    #expect(entities.map(\.originalValue) == ["Иванов"])

    let latest = try await store.latestAnonymizationRun(documentId: document.id)
    #expect(latest?.0.id == run.id)
    #expect(latest?.1.count == 1)

    let (_, replaced) = try await store.upsertAnonymizationRun(
        AnonymizationRunRecord(id: run.id, documentId: document.id, caseId: theCase.id, status: "current"),
        entities: [
            AnonymizationEntityRecord(runId: run.id, entityType: "org", originalValue: "ООО Ромашка", replacementValue: "Общество1")
        ]
    )
    #expect(replaced.map(\.originalValue) == ["ООО Ромашка"])
    #expect(try await store.latestAnonymizationRun(documentId: document.id)?.1.count == 1)

    await store.close()
}

@Test("Связи документов пишутся точечно и удаляются каскадом вместе с документом")
func связиДокументовКаскадом() async throws {
    let fixture = try await ExtensionFixture.open()
    let store = fixture.store
    let theCase = try await store.upsertCase(
        workspaceRootId: fixture.root.id, rootFolderPath: "Дело", title: "Дело"
    )
    let source = try await store.upsertWorkspaceDocument(
        workspaceRootId: fixture.root.id,
        relativePath: "Дело/иск.pdf",
        fileSize: 10,
        fileModifiedAt: Date(timeIntervalSince1970: 1_725_000_000),
        fileHash: "src"
    )
    let target = try await store.upsertWorkspaceDocument(
        workspaceRootId: fixture.root.id,
        relativePath: "Дело/договор.pdf",
        fileSize: 10,
        fileModifiedAt: Date(timeIntervalSince1970: 1_725_000_000),
        fileHash: "dst"
    )

    let relation = try await store.upsertDocumentRelation(
        DocumentRelationRecord(
            caseId: theCase.id,
            sourceDocumentId: source.id,
            targetDocumentId: target.id,
            relationType: "proves",
            payloadJSON: #"{"description":"иск доказывает договор"}"#
        )
    )
    #expect(try await store.documentRelations(caseId: theCase.id).map(\.relationType) == ["proves"])

    try await store.replaceDocumentRelations(
        caseId: theCase.id,
        relations: [
            DocumentRelationRecord(
                id: relation.id,
                caseId: theCase.id,
                sourceDocumentId: source.id,
                targetDocumentId: target.id,
                relationType: "references"
            )
        ]
    )
    #expect(try await store.documentRelations(caseId: theCase.id).map(\.relationType) == ["references"])

    _ = try await store.removeDocuments(in: .documents(ids: [source.id]))
    #expect(try await store.documentRelations(caseId: theCase.id).isEmpty)

    await store.close()
}

@Test("Читатель не пишет расширения Finder")
func читательНеПишетРасширения() async throws {
    let fixture = try await ExtensionFixture.open()
    let theCase = try await fixture.store.upsertCase(
        workspaceRootId: fixture.root.id, rootFolderPath: "Дело", title: "Дело"
    )
    let reader = try await fixture.temp.openReader()
    await #expect(throws: DocumentIndexError.readOnly) {
        try await reader.upsertCaseCard(CaseCardRecord(caseId: theCase.id))
    }
    await reader.close()
    await fixture.store.close()
}

@Test("Очистка обезличенной копии удаляет карту и вхождения, сохраняя исходник")
func очисткаОбезличеннойКопии() async throws {
    let fixture = try await ExtensionFixture.open()
    let store = fixture.store
    let document = try await store.upsertWorkspaceDocument(
        workspaceRootId: fixture.root.id, relativePath: "письмо.docx", fileSize: 12,
        fileModifiedAt: Date(), fileHash: "test"
    )
    let source = try await store.attachText(documentId: document.id, type: .original, content: "Иванов Иван Иванович")
    let result = try await store.attachText(documentId: document.id, type: .anonymized,
        content: "[ФИО 1]", sourceVariantId: source.variant.id)
    let (run, _) = try await store.upsertAnonymizationRun(
        AnonymizationRunRecord(documentId: document.id, sourceTextVariantId: source.variant.id,
            resultTextVariantId: result.variant.id, status: "reviewed"),
        entities: [AnonymizationEntityRecord(id: "entity", runId: "", entityType: "person",
            originalValue: "Иванов Иван Иванович", replacementValue: "[ФИО 1]")],
        occurrences: [AnonymizationOccurrenceRecord(entityId: "entity", sourceStartOffset: 0, sourceEndOffset: 19)]
    )
    #expect(try await store.anonymizationOccurrences(runId: run.id).count == 1)
    try await store.clearAnonymization(documentId: document.id)
    #expect(try await store.documentText(documentId: document.id, type: .anonymized) == nil)
    #expect(try await store.latestAnonymizationRun(documentId: document.id) == nil)
    #expect(try await store.anonymizationOccurrences(runId: run.id).isEmpty)
    #expect(try await store.documentText(documentId: document.id, type: .original) == "Иванов Иван Иванович")
    #expect(try await store.chunkCount(in: .everything, variantFilter: .anonymized) == 0)
    await store.close()
}

private struct ExtensionFixture {
    let temp: TemporaryDatabase
    let store: DocumentIndexStore
    let root: WorkspaceRootRecord

    static func open() async throws -> ExtensionFixture {
        let temp = TemporaryDatabase()
        let store = try await temp.openWriter()
        let root = try await store.registerWorkspaceRoot(name: "РАБОТА", localPath: "/Users/test/РАБОТА")
        return ExtensionFixture(temp: temp, store: store, root: root)
    }
}
