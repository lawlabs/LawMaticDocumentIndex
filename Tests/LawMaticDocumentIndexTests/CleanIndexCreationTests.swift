import Foundation
import SQLite
import Testing
@testable import LawMaticDocumentIndex

@Test("Новая база создаётся пустой: 0 документов, текстов и чанков, без ключей v1_import")
func emptyIndexHasNoLegacyImportMetadata() async throws {
    let corpus = try AcceptanceCorpus()
    let store = DocumentIndexStore(databaseURL: corpus.location.databaseURL, mode: .readWrite)
    try await store.open()

    #expect(try await store.documentCount(in: .everything) == 0)
    #expect(try tableCount(corpus.location.databaseURL, "texts") == 0)
    #expect(try await store.chunkCount(in: .everything) == 0)
    #expect(try await store.metadata("v1_import_disabled") == nil)
    #expect(try await store.metadata("v1_import.catalog2.case.x") == nil)
    let generation = try await store.metadata(DocumentIndexSchema.MetadataKey.indexGeneration)
    #expect(generation?.isEmpty == false)

    let search = DocumentIndexSearch(store: store, embedding: .init(provider: FakeEmbeddingProvider()))
    for mode: UnifiedDocumentSearchMode in [.keyword, .semantic, .hybrid, .auto] {
        let execution = try await search.search(.init(query: "кварцозавр", scope: .everything, mode: mode))
        #expect(execution.results.isEmpty, "режим \(mode.rawValue) должен быть пустым")
    }
    let coverage = try await store.embeddingCoverage(in: .everything, modelId: "fake-hash-32")
    #expect(coverage.totalChunks == 0)
    #expect(coverage.embeddedChunks == 0)
    #expect(coverage.isComplete == false)

    await store.close()
}

@Test("Соседняя v1 с контрольным словом не попадает в новую v2")
func neighboringV1DoesNotLeakIntoEmptyV2() async throws {
    let corpus = try AcceptanceCorpus()
    try corpus.writeNeighboringV1()
    #expect(FileManager.default.fileExists(atPath: corpus.location.shareDirectory.appendingPathComponent("LawMaticCaseDatabase.sqlite").path))

    let store = DocumentIndexStore(databaseURL: corpus.location.databaseURL, mode: .readWrite)
    try await store.open()
    #expect(try await store.documentCount(in: .everything) == 0)
    let hits = try await store.searchChunksKeyword(query: AcceptanceCorpus.legacyMarker, scope: .everything)
    #expect(hits.hits.isEmpty)
    let nameHits = try await store.searchDocumentsByName(query: AcceptanceCorpus.legacyMarker, scope: .everything)
    #expect(nameHits.isEmpty)
    await store.close()
}

@Test("Повреждённая соседняя v1 не мешает открыть пустую v2")
func corruptNeighboringV1DoesNotBlockNewIndex() async throws {
    let corpus = try AcceptanceCorpus()
    try corpus.writeCorruptV1()
    let store = DocumentIndexStore(databaseURL: corpus.location.databaseURL, mode: .readWrite)
    try await store.open()
    #expect(try await store.documentCount(in: .everything) == 0)
    #expect(try await store.integrityCheck().isEmpty)
    await store.close()
}

@Test("Повторный ingest того же файла не создаёт второй документ и не размножает текст")
func ingestSameFileTwiceIsIdempotent() async throws {
    let env = try await CleanIndexEnv()
    let file = env.corpus.macAWork.appendingPathComponent("Client-1/Case-1/claim.txt")
    let hash = try env.corpus.fileSHA256(at: file)
    let location = IndexedFileLocation.workspace(
        rootId: env.root.id,
        relativePath: "Client-1/Case-1/claim.txt"
    )
    let first = try await env.store.ingestFile(
        location: location,
        fileSize: Int64((try Data(contentsOf: file)).count),
        modifiedAt: Date(),
        fileHash: hash,
        content: env.corpus.claimText,
        extraction: .init(documentId: "", status: .complete)
    )
    let second = try await env.store.ingestFile(
        location: location,
        fileSize: Int64((try Data(contentsOf: file)).count),
        modifiedAt: Date(),
        fileHash: hash,
        content: env.corpus.claimText,
        extraction: .init(documentId: "", status: .complete)
    )
    #expect(first.id == second.id)
    #expect(try await env.store.documentCount(in: .everything) == 1)
    #expect(try tableCount(env.corpus.location.databaseURL, "texts") == 1)
    let chunks = try await env.store.chunkCount(in: .everything)
    #expect(try tableCount(env.corpus.location.databaseURL, "chunks") == chunks)
    let hits = try await env.store.searchChunksKeyword(query: "кварцозавр", scope: .everything)
    #expect(hits.hits.map(\.documentId) == [first.id])
}

@Test("Закрытие, удаление sqlite+WAL/SHM и новое поколение дают пустую базу")
func replacingGenerationCreatesEmptyIndex() async throws {
    let env = try await CleanIndexEnv()
    _ = try await env.store.ingestFile(
        location: .workspace(rootId: env.root.id, relativePath: "Client-1/Case-1/claim.txt"),
        fileSize: 10,
        modifiedAt: Date(),
        fileHash: "hash-1",
        content: env.corpus.claimText,
        extraction: .init(documentId: "", status: .complete)
    )
    let oldGeneration = try await env.store.metadata(DocumentIndexSchema.MetadataKey.indexGeneration)
    await env.store.close()

    try DocumentIndexDatabaseFiles.removeGeneration(at: env.corpus.location.databaseURL)
    #expect(!FileManager.default.fileExists(atPath: env.corpus.location.databaseURL.path))

    let replacement = DocumentIndexStore(databaseURL: env.corpus.location.databaseURL, mode: .readWrite)
    try await replacement.open()
    #expect(try await replacement.documentCount(in: .everything) == 0)
    #expect(try tableCount(env.corpus.location.databaseURL, "texts") == 0)
    #expect(try await replacement.searchChunksKeyword(query: "кварцозавр", scope: .everything).hits.isEmpty)
    let newGeneration = try await replacement.metadata(DocumentIndexSchema.MetadataKey.indexGeneration)
    #expect(newGeneration != oldGeneration)
    #expect(try await replacement.metadata("v1_import_disabled") == nil)
    await replacement.close()
}

@Test("clearIndex не выставляет v1_import_disabled и не управляет новым наполнением")
func clearIndexDoesNotSetLegacyImportFlag() async throws {
    let env = try await CleanIndexEnv()
    _ = try await env.store.ingestFile(
        location: .workspace(rootId: env.root.id, relativePath: "Client-1/Case-1/claim.txt"),
        fileSize: 10,
        modifiedAt: Date(),
        fileHash: "hash-1",
        content: env.corpus.claimText,
        extraction: .init(documentId: "", status: .complete)
    )
    try await env.store.clearIndex()
    #expect(try await env.store.metadata("v1_import_disabled") == nil)
    #expect(try await env.store.documentCount(in: .everything) == 0)

    _ = try await env.store.ingestFile(
        location: .workspace(rootId: env.root.id, relativePath: "Client-1/Case-1/claim.txt"),
        fileSize: 10,
        modifiedAt: Date(),
        fileHash: "hash-1",
        content: env.corpus.claimText,
        extraction: .init(documentId: "", status: .complete, finishedAt: Date()),
        extractionStartedAt: Date(timeIntervalSinceNow: 1)
    )
    #expect(try await env.store.documentCount(in: .everything) == 1)
}

@Test("Пути корпуса и базы задаются явно, без UserDefaults и без /Users/sergey/РАБОТА")
func acceptancePathsAreInjected() throws {
    let corpus = try AcceptanceCorpus()
    #expect(corpus.location.databaseURL.path.hasPrefix(corpus.directoryURL.path))
    #expect(!corpus.location.databaseURL.path.contains("РАБОТА"))
    #expect(!corpus.macAWork.path.contains("/Users/sergey/РАБОТА"))
    #expect(FileManager.default.fileExists(atPath: corpus.macAWork.appendingPathComponent("Client-1/Case-1/claim.txt").path))
    #expect(FileManager.default.fileExists(atPath: corpus.macBDocuments.appendingPathComponent("Client-1/Case-1/claim.txt").path))
    #expect(FileManager.default.fileExists(atPath: corpus.macAWork.appendingPathComponent("Client-1/Case-1/договор % & # +.txt").path))
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

private final class OpenedFiles: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    func record(_ url: URL) { lock.withLock { paths.append(url.standardizedFileURL.path) } }
    var all: [String] { lock.withLock { paths } }
}

@Test("Старый файл, переименованная копия и symlink в рабочем корне не открываются как база")
func noLegacyDiscoveryAtAlternateRoot() async throws {
    let corpus = try AcceptanceCorpus()
    let fm = FileManager.default
    let old = corpus.macAWork.appendingPathComponent("LawMaticCaseDatabase.sqlite")
    let renamed = corpus.macAWork.appendingPathComponent("renamed-backup.sqlite")
    let target = corpus.directoryURL.appendingPathComponent("outside-root-target.sqlite")
    let link = corpus.macAWork.appendingPathComponent("legacy-link.sqlite")
    let bytes = Data("legacy sentinel file".utf8)
    for url in [old, renamed, target] { try bytes.write(to: url) }
    try fm.createSymbolicLink(at: link, withDestinationURL: target)
    let opened = OpenedFiles()
    let store = DocumentIndexStore(databaseURL: corpus.location.databaseURL, connectionObserver: { url, _ in opened.record(url) })
    try await store.open()
    let root = try await store.registerWorkspaceRoot(name: "Work", localPath: corpus.macAWork.path)
    _ = try await store.ensureCase(workspaceRootId: root.id, rootFolderPath: "Client-1/Case-1", title: "Case")
    try await store.clearIndex()
    await store.close(); try await store.open(); await store.close()
    #expect(opened.all.count == 2)
    #expect(opened.all.allSatisfy { $0 == corpus.location.databaseURL.path })
    for url in [old, renamed, target, link] { #expect(try Data(contentsOf: url) == bytes) }
    #expect(!fm.fileExists(atPath: corpus.macAWork.appendingPathComponent(DocumentIndexSchema.fileName).path))
    try fm.removeItem(at: link)
    #expect(try Data(contentsOf: target) == bytes)
}
