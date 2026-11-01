import Foundation
import SQLite
import Testing
@testable import LawMaticDocumentIndex

@Test("Повторный ingest сохраняет document id, метаданные и не плодит карточку")
func повторныйIngestСохраняетМетаданныеИИдентификатор() async throws {
    let env = try await CleanIndexEnv()
    let path = "Client-1/Case-1/claim.txt"
    let location = IndexedFileLocation.workspace(rootId: env.root.id, relativePath: path)
    let first = try await env.store.ingestFile(
        location: location,
        fileSize: 40,
        modifiedAt: Date(),
        fileHash: "hash-original",
        content: env.corpus.claimText,
        extraction: .init(documentId: "", status: .complete)
    )
    _ = try await env.store.upsertDocumentUserMetadata(
        DocumentUserMetadataRecord(
            documentId: first.id,
            notes: "заметка юриста",
            confidentiality: "restricted",
            isEvidence: true,
            tagsJSON: #"["договор"]"#
        )
    )

    let second = try await env.store.ingestFile(
        location: location,
        fileSize: 48,
        modifiedAt: Date(),
        fileHash: "hash-replaced",
        content: "Новый текст иска без прежнего контрольного слова.",
        extraction: .init(documentId: "", status: .complete)
    )
    #expect(second.id == first.id)
    #expect(try await env.store.documentCount(in: .everything) == 1)
    let meta = try await env.store.documentUserMetadata(documentId: first.id)
    #expect(meta?.notes == "заметка юриста")
    #expect(meta?.confidentiality == "restricted")
    #expect(meta?.isEvidence == true)
    #expect(try await env.store.documentText(documentId: first.id) == "Новый текст иска без прежнего контрольного слова.")
    await env.store.close()
}

@Test("Замена original скрывает устаревший anonymized из поиска и хранит историю")
func заменаOriginalСкрываетУстаревшийAnonymized() async throws {
    let env = try await CleanIndexEnv()
    let path = "Client-1/Case-1/claim.txt"
    let location = IndexedFileLocation.workspace(rootId: env.root.id, relativePath: path)
    let original = "Иванов подписал договор на кварцозавр."
    let anonymized = "Сторона1 подписал договор на кварцозавр."
    let theCase = try await env.store.upsertCase(
        workspaceRootId: env.root.id,
        rootFolderPath: "Client-1/Case-1",
        title: "Case-1"
    )
    let document = try await env.store.ingestFile(
        location: location,
        fileSize: Int64(original.utf16.count),
        modifiedAt: Date(),
        fileHash: "hash-a",
        content: original,
        extraction: .init(documentId: "", status: .complete)
    )
    let source = try await env.store.textVariant(documentId: document.id, type: .original)
    let attached = try await env.store.attachText(
        documentId: document.id,
        type: .anonymized,
        content: anonymized,
        sourceVariantId: source?.id
    )
    let sourceNS = original as NSString
    let resultNS = anonymized as NSString
    let sourceRange = sourceNS.range(of: "Иванов")
    let resultRange = resultNS.range(of: "Сторона1")
    #expect(sourceRange.location != NSNotFound)
    #expect(resultRange.location != NSNotFound)

    let (run, entities) = try await env.store.upsertAnonymizationRun(
        AnonymizationRunRecord(
            documentId: document.id,
            caseId: theCase.id,
            sourceTextVariantId: source?.id,
            resultTextVariantId: attached.variant.id,
            status: "current",
            method: "rules"
        ),
        entities: [
            AnonymizationEntityRecord(
                runId: "",
                entityType: "person",
                originalValue: "Иванов",
                replacementValue: "Сторона1"
            )
        ],
        occurrences: [
            AnonymizationOccurrenceRecord(
                entityId: "",
                caseId: theCase.id,
                sourceTextVariantId: source?.id,
                resultTextVariantId: attached.variant.id,
                originalFragment: "Иванов",
                replacementFragment: "Сторона1",
                sourceStartOffset: sourceRange.location,
                sourceEndOffset: sourceRange.location + sourceRange.length,
                resultStartOffset: resultRange.location,
                resultEndOffset: resultRange.location + resultRange.length,
                occurrenceIndex: 0
            )
        ]
    )
    #expect(entities.count == 1)
    let storedOccurrences = try await env.store.anonymizationOccurrences(runId: run.id)
    #expect(storedOccurrences.count == 1)
    #expect(storedOccurrences[0].sourceStartOffset == sourceRange.location)
    #expect(storedOccurrences[0].sourceEndOffset == sourceRange.location + sourceRange.length)

    let originalHits = try await env.store.searchChunksKeyword(
        query: "Иванов", scope: .everything, variantFilter: .original
    )
    #expect(originalHits.hits.map(\.documentId) == [document.id])
    let anonymizedHits = try await env.store.searchChunksKeyword(
        query: "Сторона1", scope: .everything, variantFilter: .anonymized
    )
    #expect(anonymizedHits.hits.map(\.documentId) == [document.id])
    let allHits = try await env.store.searchChunksKeyword(
        query: "кварцозавр", scope: .everything, variantFilter: .all
    )
    #expect(Set(allHits.hits.map(\.variantType)) == ["original", "anonymized"])

    _ = try await env.store.ingestFile(
        location: location,
        fileSize: 20,
        modifiedAt: Date(),
        fileHash: "hash-b",
        content: "Новый текст без прежних имён.",
        extraction: .init(documentId: "", status: .complete)
    )
    #expect(try await env.store.document(id: document.id)?.id == document.id)
    #expect(try await env.store.documentText(documentId: document.id, type: .original) == "Новый текст без прежних имён.")
    #expect(try await env.store.documentText(documentId: document.id, type: .anonymized) == nil)
    #expect(
        try await env.store.searchChunksKeyword(
            query: "Иванов", scope: .everything, variantFilter: .original
        ).hits.isEmpty
    )
    #expect(
        try await env.store.searchChunksKeyword(
            query: "Сторона1", scope: .everything, variantFilter: .anonymized
        ).hits.isEmpty
    )
    #expect(
        try await env.store.searchChunksKeyword(
            query: "Новый", scope: .everything, variantFilter: .original
        ).hits.map(\.documentId) == [document.id]
    )
    #expect(try tableCount(env.corpus.location.databaseURL, "text_variant_history") >= 1)
    #expect(try await env.store.anonymizationOccurrences(runId: run.id).count == 1)
    await env.store.close()
}

private final class CleanIndexEnv {
    let corpus: AcceptanceCorpus
    let store: DocumentIndexStore
    let root: WorkspaceRootRecord

    init() async throws {
        corpus = try AcceptanceCorpus()
        store = DocumentIndexStore(
            databaseURL: corpus.location.databaseURL,
            mode: .readWrite,
            workspacePaths: [AcceptanceCorpus.workRootId: corpus.macAWork.path]
        )
        try await store.open()
        root = try await store.registerWorkspaceRoot(
            id: AcceptanceCorpus.workRootId,
            name: "Work",
            localPath: corpus.macAWork.path
        )
    }
}

private func tableCount(_ databaseURL: URL, _ table: String) throws -> Int {
    let db = try SQLite.Connection(databaseURL.path, readonly: true)
    let value = try db.scalar("SELECT COUNT(*) FROM \(table)")
    if let int64 = value as? Int64 { return Int(int64) }
    if let int = value as? Int { return int }
    return 0
}
