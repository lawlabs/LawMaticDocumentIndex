import Foundation
import Testing
@testable import LawMaticDocumentIndex

@Test("Недоступный root остаётся в выдаче по имени, оригинал помечен")
func недоступныйКореньВиденВПоискеПоИмени() async throws {
    let temp = TemporaryDatabase()
    let store = try await temp.openWriter()
    let root = try await store.registerWorkspaceRoot(name: "Work", localPath: "/tmp/work-a")
    let document = try await store.upsertWorkspaceDocument(
        workspaceRootId: root.id,
        relativePath: "Дело/иск.txt",
        fileSize: 12,
        fileModifiedAt: Date(),
        fileHash: "abc"
    )
    _ = try await store.ingestFile(
        location: .workspace(rootId: root.id, relativePath: "Дело/иск.txt"),
        fileSize: 12,
        modifiedAt: Date(),
        fileHash: "abc",
        content: "исковое заявление кварцозавр",
        extraction: ExtractionState(documentId: "", status: .complete)
    )
    let bound = try await store.searchDocumentsByName(query: "иск", scope: .workspaceRoot(id: root.id))
    #expect(bound.map(\.id).contains(document.id))
    try await store.setWorkspacePaths([:])
    let unbound = try await store.searchDocumentsByName(query: "иск", scope: .workspaceRoot(id: root.id))
    #expect(unbound.map(\.id).contains(document.id), "запись индекса не скрывается без локального пути")
    let location = try await store.resolvedLocation(for: document)
    #expect(!location.isOriginalAvailable)
    #expect(DocumentIndexPath.isUnavailableURL(location.fileURL))
    let hits = try await store.searchChunksKeyword(query: "кварцозавр", scope: .workspaceRoot(id: root.id))
    #expect(!hits.hits.isEmpty)
    #expect(hits.hits.contains { DocumentIndexPath.isUnavailableURL($0.fileURL) })
    await store.close()
}
