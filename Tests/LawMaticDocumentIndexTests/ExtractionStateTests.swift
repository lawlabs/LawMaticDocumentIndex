import Foundation
import Testing
@testable import LawMaticDocumentIndex

@Test("Состояние извлечения: upsert, счётчики и очередь с учётом retry и версии")
func состояниеИзвлеченияUpsertСчётчикиИОчередь() async throws {
    let temp = TemporaryDatabase()
    let store = try await temp.openWriter()
    let root = try await store.registerWorkspaceRoot(name: "РАБОТА", localPath: "/Users/test/extract")
    let modified = Date(timeIntervalSince1970: 1_725_000_000)

    let pendingDoc = try await store.upsertWorkspaceDocument(
        workspaceRootId: root.id, relativePath: "pending.docx",
        fileSize: 1, fileModifiedAt: modified, fileHash: nil
    )
    let completeDoc = try await store.upsertWorkspaceDocument(
        workspaceRootId: root.id, relativePath: "complete.pdf",
        fileSize: 1, fileModifiedAt: modified, fileHash: nil
    )
    let failedSoon = try await store.upsertWorkspaceDocument(
        workspaceRootId: root.id, relativePath: "failed-soon.pdf",
        fileSize: 1, fileModifiedAt: modified, fileHash: nil
    )
    let failedLater = try await store.upsertWorkspaceDocument(
        workspaceRootId: root.id, relativePath: "failed-later.pdf",
        fileSize: 1, fileModifiedAt: modified, fileHash: nil
    )
    let staleComplete = try await store.upsertWorkspaceDocument(
        workspaceRootId: root.id, relativePath: "stale.pdf",
        fileSize: 1, fileModifiedAt: modified, fileHash: nil
    )
    let bare = try await store.upsertWorkspaceDocument(
        workspaceRootId: root.id, relativePath: "bare.docx",
        fileSize: 1, fileModifiedAt: modified, fileHash: nil
    )

    try await store.setExtractionState(ExtractionState(documentId: pendingDoc.id, status: .pending, attempts: 1))
    try await store.setExtractionState(ExtractionState(
        documentId: pendingDoc.id,
        status: .complete,
        extractorId: "pdf",
        extractorVersion: 2,
        methodLabel: "PDFKit",
        pagesTotal: 3,
        pagesProcessed: 3,
        attempts: 2,
        finishedAt: modified
    ))
    let upserted = try await store.extractionState(documentId: pendingDoc.id)
    #expect(upserted?.status == .complete)
    #expect(upserted?.extractorVersion == 2)
    #expect(upserted?.attempts == 2)

    try await store.setExtractionState(ExtractionState(
        documentId: completeDoc.id, status: .complete, extractorId: "pdf", extractorVersion: 2
    ))
    try await store.setExtractionState(ExtractionState(
        documentId: failedSoon.id,
        status: .failed,
        errorCode: ExtractionErrorCode.readFailed.rawValue,
        nextRetryAfter: Date().addingTimeInterval(-30)
    ))
    try await store.setExtractionState(ExtractionState(
        documentId: failedLater.id,
        status: .failed,
        nextRetryAfter: Date().addingTimeInterval(3600)
    ))
    try await store.setExtractionState(ExtractionState(
        documentId: staleComplete.id, status: .complete, extractorId: "pdf", extractorVersion: 1
    ))

    let counts = try await store.extractionStatusCounts(in: .workspaceRoot(id: root.id))
    #expect(counts[.complete] == 3)
    #expect(counts[.failed] == 2)
    #expect(counts[.pending] == 0)

    let failedOnly = try await store.extractionStates(in: .everything, statuses: [.failed])
    #expect(Set(failedOnly.map(\.documentId)) == [failedSoon.id, failedLater.id])

    let needing = try await store.documentsNeedingExtraction(
        in: .workspaceRoot(id: root.id),
        extractorVersions: ["pdf": 2]
    )
    let needingIds = Set(needing.map(\.id))
    #expect(needingIds.contains(bare.id), "нет состояния — нужна очередь")
    #expect(needingIds.contains(failedSoon.id), "истёк next_retry_after")
    #expect(needingIds.contains(staleComplete.id), "версия экстрактора ниже переданной")
    #expect(!needingIds.contains(failedLater.id), "повтор ещё рано")
    #expect(!needingIds.contains(completeDoc.id), "актуальная версия не переизвлекается")
    #expect(!needingIds.contains(pendingDoc.id), "complete с той же версией не в очереди")

    let ocrOff = try await store.upsertWorkspaceDocument(
        workspaceRootId: root.id, relativePath: "ocr-off.pdf",
        fileSize: 1, fileModifiedAt: modified, fileHash: nil
    )
    try await store.setExtractionState(ExtractionState(
        documentId: ocrOff.id,
        status: .failed,
        errorCode: "ocr_disabled",
        nextRetryAfter: Date().addingTimeInterval(-30)
    ))
    #expect(
        !(try await store.documentsNeedingExtraction(in: .workspaceRoot(id: root.id)).map(\.id).contains(ocrOff.id)),
        "OCR off не ставится в автоматический повтор"
    )

    try await store.markExtractionPending(documentIds: [completeDoc.id])
    #expect(try await store.extractionState(documentId: completeDoc.id)?.status == .pending)
    #expect(try await store.documentsNeedingExtraction(in: .everything).map(\.id).contains(completeDoc.id))
}
