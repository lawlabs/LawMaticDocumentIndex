import Foundation
import SQLite
import Testing
@testable import LawMaticDocumentIndex

@Test("A supplied legacy snapshot upgrades without losing catalogue or texts", .enabled(if: ProcessInfo.processInfo.environment["LAWMATIC_TEST_SNAPSHOT"] != nil))
func upgradeRealSnapshot() async throws {
    let source = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LAWMATIC_TEST_SNAPSHOT"]))
    let temp = TemporaryDatabase()
    try FileManager.default.createDirectory(at: temp.directoryURL, withIntermediateDirectories: true)
    let copy = temp.directoryURL.appendingPathComponent("upgrade.sqlite")
    try FileManager.default.copyItem(at: source, to: copy)
    let raw = try SQLite.Connection(copy.path)
    let documentCount = try raw.scalar("SELECT COUNT(*) FROM documents") as? Int64
    let textCount = try raw.scalar("SELECT COUNT(*) FROM texts") as? Int64
    let chunkCount = try raw.scalar("SELECT COUNT(*) FROM chunks") as? Int64
    let writer = DocumentIndexStore(databaseURL: copy, mode: .readWrite)
    try await writer.open()
    #expect(try raw.scalar("SELECT COUNT(*) FROM documents") as? Int64 == documentCount)
    #expect(try raw.scalar("SELECT COUNT(*) FROM texts") as? Int64 == textCount)
    #expect(try raw.scalar("SELECT COUNT(*) FROM chunks") as? Int64 == chunkCount)
    #expect(try raw.scalar("SELECT COUNT(*) FROM workspace_roots WHERE local_path != ''") as? Int64 == 0)
    #expect(try await writer.integrityCheck().isEmpty)
    var foreignKeyIssues = 0
    for _ in try raw.prepare("PRAGMA foreign_key_check") { foreignKeyIssues += 1 }
    #expect(foreignKeyIssues == 0)
    let reader = DocumentIndexStore(databaseURL: copy, mode: .readOnly)
    try await reader.open()
    let hits = try await reader.searchChunksKeyword(query: "договор", scope: .everything)
    #expect(!hits.hits.isEmpty)
    #expect(hits.hits.allSatisfy { !$0.fileURL.isFileURL }, "Unbound roots must not borrow another computer's absolute path")
    let exported = temp.directoryURL.appendingPathComponent("export.sqlite")
    try await writer.exportSnapshot(to: exported)
    let exportedReader = DocumentIndexStore(databaseURL: exported, mode: .readOnly)
    try await exportedReader.open()
    #expect(try await exportedReader.documentCount(in: .everything) == Int(documentCount ?? 0))
}
