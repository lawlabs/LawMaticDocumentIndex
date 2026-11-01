import Foundation
import Testing
@testable import LawMaticDocumentIndex

@Test("AI context reads nearest case, card and structured lists consistently without document text or writes")
func caseContextProjection() async throws {
    let temp = TemporaryDatabase()
    let store = try await temp.openWriter()
    let root = try await store.registerWorkspaceRoot(name: "Работа", localPath: temp.directoryURL.path)
    let parent = try await store.ensureCase(workspaceRootId: root.id, rootFolderPath: "client", title: "Клиент")
    let child = try await store.ensureCase(workspaceRootId: root.id, rootFolderPath: "client/case", title: "Иск")
    _ = try await store.saveCaseCard(workspaceRootId: root.id, rootFolderPath: "client/case", title: "Иск",
        card: .init(caseId: child.id, caseNumber: "2-123/2026", goals: "Оспорить размер"))
    try await store.upsertCaseListItems(caseId: parent.id, items: [.init(id: "parent-fact", caseId: parent.id, kind: .fact, title: "Не относится к иску")])
    try await store.upsertCaseListItems(caseId: child.id, items: [.init(id: "child-fact", caseId: child.id, kind: .fact, title: "Факт иска", payloadJSON: "{\"title\":\"Факт иска\"}")])
    let doc = try await store.upsertWorkspaceDocument(workspaceRootId: root.id, relativePath: "client/case/secret.pdf", fileSize: 10, fileModifiedAt: Date(), fileHash: nil)
    _ = try await store.attachText(documentId: doc.id, content: "SECRET DOCUMENT BODY")
    _ = try await store.upsertDocumentUserMetadata(.init(documentId: doc.id, confidentiality: "secret"))
    let snapshot = try #require(try await store.caseContext(workspaceRootId: root.id, folderRelativePath: "client/case/not-indexed-subfolder"))
    #expect(snapshot.record.id == child.id)
    #expect(snapshot.rootRelativePath == "client/case")
    #expect(snapshot.card?.goals == "Оспорить размер")
    #expect(snapshot.items.map(\.id) == ["child-fact"])
    #expect(snapshot.documentPrivacy[doc.id.lowercased()] == "secret")
    #expect(snapshot.documentPrivacy["secret.pdf"] == "secret")
    #expect(try await store.caseContext(workspaceRootId: root.id, folderRelativePath: "client/case-sibling")?.record.id == parent.id)
    #expect(try await store.caseContext(workspaceRootId: root.id, folderRelativePath: "other") == nil)
    #expect(try await store.cases(workspaceRootId: root.id).count == 2)
    #expect(try await store.documentText(documentId: doc.id) == "SECRET DOCUMENT BODY")
    let reader = DocumentIndexStore(databaseURL: temp.databaseURL, mode: .readOnly)
    try await reader.open()
    #expect(try await reader.caseContext(workspaceRootId: root.id, folderRelativePath: "client/case") == snapshot)
}

@Test("AI context keeps the strictest policy when workspace and case path aliases collide")
func caseContextPolicyCollisions() async throws {
    let temp = TemporaryDatabase()
    let store = try await temp.openWriter()
    let root = try await store.registerWorkspaceRoot(name: "Работа", localPath: temp.directoryURL.path)
    _ = try await store.ensureCase(workspaceRootId: root.id, rootFolderPath: "client/case", title: "Иск")
    let first = try await store.upsertWorkspaceDocument(workspaceRootId: root.id, relativePath: "client/case/source.pdf",
        fileSize: 10, fileModifiedAt: Date(), fileHash: nil)
    let nested = try await store.upsertWorkspaceDocument(workspaceRootId: root.id, relativePath: "client/case/client/case/source.pdf",
        fileSize: 10, fileModifiedAt: Date(), fileHash: nil)
    for (left, right) in [("secret", "public"), ("public", "secret"), ("restricted", "confidential")] {
        _ = try await store.upsertDocumentUserMetadata(.init(documentId: first.id, confidentiality: left))
        _ = try await store.upsertDocumentUserMetadata(.init(documentId: nested.id, confidentiality: right))
        let snapshot = try #require(try await store.caseContext(workspaceRootId: root.id, folderRelativePath: "client/case"))
        #expect(snapshot.documentPrivacy["client/case/source.pdf"] == (left == "restricted" ? "confidential" : "secret"))
        #expect(snapshot.documentPrivacy[first.id.lowercased()] == left)
        #expect(snapshot.documentPrivacy[nested.id.lowercased()] == right)
    }
    var aliases = ["/work/case/source.pdf": "secret"]
    CaseContextDocumentPolicy.merge("public", for: "/work/case/source.pdf", into: &aliases)
    #expect(aliases["/work/case/source.pdf"] == "secret")
    CaseContextDocumentPolicy.merge("unknown", for: "/work/case/source.pdf", into: &aliases)
    CaseContextDocumentPolicy.merge("public", for: "/work/case/source.pdf", into: &aliases)
    #expect(aliases["/work/case/source.pdf"] == "unknown")
}
