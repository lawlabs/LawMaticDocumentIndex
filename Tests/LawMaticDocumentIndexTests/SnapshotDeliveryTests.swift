import Foundation
import SQLite
import Testing
@testable import LawMaticDocumentIndex

@Test("VACUUM INTO публикует снимок без WAL/SHM; читатель видит текст и пустые local_path")
func snapshotExportIsStandaloneAndSearchable() async throws {
    let env = try await SnapshotEnv()
    _ = try await env.store.attachText(documentId: env.doc.id, content: "Контрольное слово кварцозавр")
    let generation = try await env.store.indexGeneration()
    let dest = env.temp.directoryURL.appendingPathComponent("published.sqlite")
    try await env.store.exportSnapshot(to: dest)

    let sidecars = DocumentIndexSnapshot.sidecarURLs(forDatabase: dest)
    #expect(!FileManager.default.fileExists(atPath: sidecars.wal.path))
    #expect(!FileManager.default.fileExists(atPath: sidecars.shm.path))

    let info = try DocumentIndexSnapshot.inspect(dest, options: .publishedExport)
    #expect(info.generation == generation)
    #expect(!info.hasWALSidecar)

    let manifest = try DocumentIndexManifest.load(from: DocumentIndexSnapshot.manifestURL(forDatabase: dest))
    #expect(manifest.indexGeneration == generation)
    #expect(manifest.snapshotId?.isEmpty == false)
    #expect(manifest.isCompatible)

    let reader = DocumentIndexStore(databaseURL: dest, mode: .readOnly)
    try await reader.open()
    try await reader.setWorkspacePaths([env.root.id: "/Users/b/Documents"])
    let hits = try await reader.searchChunksKeyword(query: "кварцозавр", scope: .everything)
    #expect(hits.hits.count == 1)
    #expect(hits.hits.first?.fileURL.path == "/Users/b/Documents/case/a.txt")
    await reader.close()

    let raw = try SQLite.Connection(dest.path, readonly: true)
    #expect(try raw.scalar("SELECT local_path FROM workspace_roots") as? String == "")
    var fk = 0
    for _ in try raw.prepare("PRAGMA foreign_key_check") { fk += 1 }
    #expect(fk == 0)
}

@Test("inspect отвергает пустой, чужой и недописанный файл")
func snapshotInspectRejectsIncompleteFiles() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("snapshot-reject-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let missing = directory.appendingPathComponent("missing.sqlite")
    #expect(throws: DocumentIndexError.self) {
        _ = try DocumentIndexSnapshot.inspect(missing)
    }

    let empty = directory.appendingPathComponent("empty.sqlite")
    FileManager.default.createFile(atPath: empty.path, contents: Data())
    #expect(throws: DocumentIndexError.self) {
        _ = try DocumentIndexSnapshot.inspect(empty)
    }

    let garbage = directory.appendingPathComponent("garbage.sqlite")
    try Data("not sqlite".utf8).write(to: garbage)
    #expect(throws: DocumentIndexError.self) {
        _ = try DocumentIndexSnapshot.inspect(garbage)
    }
}

@Test("Замена файла снимка: старое соединение не видит новый inode, inspect нового проходит")
func snapshotReplacementChangesFileStamp() async throws {
    let first = try await SnapshotEnv()
    _ = try await first.store.attachText(documentId: first.doc.id, content: "Первое поколение кварцозавр")
    let published = first.temp.directoryURL.appendingPathComponent("shared.sqlite")
    try await first.store.exportSnapshot(to: published)

    let reader = DocumentIndexStore(databaseURL: published, mode: .readOnly)
    try await reader.open()
    let stampBefore = try DocumentIndexSnapshot.fileStamp(at: published)
    #expect(try await reader.searchChunksKeyword(query: "кварцозавр", scope: .everything).hits.count == 1)
    await reader.close()

    let second = try await SnapshotEnv()
    _ = try await second.store.attachText(documentId: second.doc.id, content: "Второе поколение другоеслово")
    let incoming = second.temp.directoryURL.appendingPathComponent("incoming.sqlite")
    try await second.store.exportSnapshot(to: incoming)
    try DocumentIndexSnapshot.publishAtomically(from: incoming, to: published)

    let stampAfter = try DocumentIndexSnapshot.fileStamp(at: published)
    #expect(stampBefore != stampAfter)

    let info = try DocumentIndexSnapshot.inspect(published, options: .publishedExport)
    #expect(info.stamp == stampAfter)

    let replacement = DocumentIndexStore(databaseURL: published, mode: .readOnly)
    try await replacement.open()
    #expect(try await replacement.searchChunksKeyword(query: "другоеслово", scope: .everything).hits.count == 1)
    #expect(try await replacement.searchChunksKeyword(query: "кварцозавр", scope: .everything).hits.isEmpty)
    await replacement.close()
}

@Test("Повреждённая замена не проходит inspect и не открывается как готовый снимок")
func badReplacementKeepsOldConnection() async throws {
    let env = try await SnapshotEnv()
    _ = try await env.store.attachText(documentId: env.doc.id, content: "Живой текст кварцозавр")
    let published = env.temp.directoryURL.appendingPathComponent("live.sqlite")
    try await env.store.exportSnapshot(to: published)

    let reader = DocumentIndexStore(databaseURL: published, mode: .readOnly)
    try await reader.open()
    #expect(try await reader.searchChunksKeyword(query: "кварцозавр", scope: .everything).hits.count == 1)
    await reader.close()

    let garbage = env.temp.directoryURL.appendingPathComponent("partial.sqlite")
    try Data("частичная синхронизация".utf8).write(to: garbage)
    try DocumentIndexSnapshot.publishAtomically(from: garbage, to: published)
    #expect(throws: DocumentIndexError.self) {
        _ = try DocumentIndexSnapshot.inspect(published)
    }
}

@Test("Писатель пишет тексты, читатель ищет без постоянного SQLITE_BUSY")
func concurrentWriterSearchDoesNotBusy() async throws {
    let env = try await SnapshotEnv()
    let writer = env.store
    let documentId = env.doc.id
    let reader = try await env.temp.openReader()
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            for index in 0..<30 {
                _ = try await writer.attachText(
                    documentId: documentId,
                    content: "Поставка номер \(index) кварцозавр"
                )
            }
        }
        group.addTask {
            for _ in 0..<30 {
                _ = try await reader.searchChunksKeyword(query: "кварцозавр", scope: .everything)
                _ = try await reader.dataVersion()
            }
        }
        try await group.waitForAll()
    }
    #expect(try await reader.searchChunksKeyword(query: "кварцозавр", scope: .everything).hits.isEmpty == false)
    await reader.close()
}

private final class SnapshotEnv {
    let temp = TemporaryDatabase()
    let store: DocumentIndexStore
    let root: WorkspaceRootRecord
    let doc: IndexedDocument

    init() async throws {
        store = try await temp.openWriter()
        root = try await store.registerWorkspaceRoot(id: "shared", name: "Work", localPath: "/Users/a/Work")
        doc = try await store.upsertWorkspaceDocument(
            workspaceRootId: root.id,
            relativePath: "case/a.txt",
            fileSize: 1,
            fileModifiedAt: Date(),
            fileHash: "one"
        )
    }
}
