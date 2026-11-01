import Foundation
import SQLite
import Testing
@testable import LawMaticDocumentIndex

@Test("enqueueJob не дублирует активную задачу, после completeJob разрешает новую")
func очередьНеДублируетАктивнуюЗадачу() async throws {
    let temp = TemporaryDatabase()
    let store = try await temp.openWriter()
    let first = try await store.enqueueJob(kind: .extract, target: IndexJobRecord.documentTarget("doc-1"), priority: 1)
    let again = try await store.enqueueJob(kind: .extract, target: IndexJobRecord.documentTarget("doc-1"), priority: 9)
    #expect(first.id == again.id)
    #expect(again.priority == 1)
    #expect(again.state == .queued)

    try await store.completeJob(id: first.id)
    let next = try await store.enqueueJob(kind: .extract, target: IndexJobRecord.documentTarget("doc-1"))
    #expect(next.id != first.id)
    #expect(next.state == .queued)
}

@Test("claimNextJobs соблюдает приоритет и не отдаёт одну задачу дважды")
func захватЗадачПоПриоритету() async throws {
    let temp = TemporaryDatabase()
    let store = try await temp.openWriter()
    let low = try await store.enqueueJob(kind: .extract, target: "doc:low", priority: 1)
    let high = try await store.enqueueJob(kind: .extract, target: "doc:high", priority: 10)

    let first = try await store.claimNextJobs(kind: .extract, limit: 1)
    #expect(first.map(\.id) == [high.id])
    #expect(first[0].state == .running)
    #expect(first[0].attempts == 1)

    let second = try await store.claimNextJobs(kind: .extract, limit: 1)
    #expect(second.map(\.id) == [low.id])

    let empty = try await store.claimNextJobs(kind: .extract, limit: 2)
    #expect(empty.isEmpty)

    let embed = try await store.enqueueJob(kind: .embed, target: "text:h", priority: 100)
    let claimedEmbed = try await store.claimNextJobs(kind: .embed, limit: 1)
    #expect(claimedEmbed.map(\.id) == [embed.id])
}

@Test("failJob(requeue:) возвращает в очередь или помечает failed")
func ошибкаЗадачиСПовторомИБез() async throws {
    let temp = TemporaryDatabase()
    let store = try await temp.openWriter()
    let job = try await store.enqueueJob(kind: .extract, target: "doc:x")
    _ = try await store.claimNextJobs(kind: .extract, limit: 1)

    try await store.failJob(id: job.id, error: "таймаут", requeue: true)
    let queued = try await store.jobs(kind: .extract, states: [.queued])
    #expect(queued.count == 1)
    #expect(queued[0].lastError == "таймаут")
    #expect(queued[0].state == .queued)

    let claimed = try await store.claimNextJobs(kind: .extract, limit: 1)
    #expect(claimed[0].id == job.id)
    #expect(claimed[0].attempts == 2)

    try await store.failJob(id: job.id, error: "окончательно", requeue: false)
    #expect(try await store.jobs(states: [.failed]).map(\.id) == [job.id])
    #expect(try await store.claimNextJobs(kind: .extract, limit: 1).isEmpty)
}

@Test("requeueFailedJobs возвращает failed в queued без смены attempts")
func повторFailedЗадач() async throws {
    let temp = TemporaryDatabase()
    let store = try await temp.openWriter()
    let job = try await store.enqueueJob(kind: .extract, target: "doc:retry")
    _ = try await store.claimNextJobs(kind: .extract, limit: 1)
    try await store.failJob(id: job.id, error: "сеть", requeue: false)
    #expect(try await store.jobs(states: [.failed]).count == 1)

    #expect(try await store.requeueFailedJobs(kind: .extract) == 1)
    let queued = try await store.jobs(kind: .extract, states: [.queued])
    #expect(queued.map(\.id) == [job.id])
    #expect(queued[0].attempts == 1)
    #expect(queued[0].lastError == "сеть")
}

@Test("resetRunningJobs возвращает зависшие running в queued")
func сбросЗависшихRunning() async throws {
    let temp = TemporaryDatabase()
    let store = try await temp.openWriter()
    let job = try await store.enqueueJob(kind: .extract, target: "doc:hang")
    _ = try await store.claimNextJobs(kind: .extract, limit: 1)
    #expect(try await store.jobs(states: [.running]).count == 1)

    let reset = try await store.resetRunningJobs()
    #expect(reset == 1)
    #expect(try await store.jobs(states: [.queued]).map(\.id) == [job.id])
    #expect(try await store.jobs(states: [.running]).isEmpty)
}

@Test("enqueueEmbedJobs ставит задачи только для непокрытых текстов и идемпотентен")
func постановкаEmbedЗадачПоНепокрытым() async throws {
    let temp = TemporaryDatabase()
    let store = try await temp.openWriter()
    let db = try temp.rawConnection(readonly: false)
    try db.execute("PRAGMA foreign_keys = ON")
    try RawFixtures.insertWorkspaceRoot(db, id: "ws")
    try RawFixtures.insertCase(db, id: "case-a", workspaceRootId: "ws", rootFolderPath: "ДелоА", title: "А")
    try RawFixtures.insertWorkspaceDocument(
        db, id: "doc-a", workspaceRootId: "ws", relativePath: "ДелоА/a.docx", caseId: "case-a"
    )
    try RawFixtures.insertWorkspaceDocument(
        db, id: "doc-b", workspaceRootId: "ws", relativePath: "ДелоА/b.docx", caseId: "case-a"
    )
    let uncovered = try RawFixtures.insertText(db, hash: "h-open", content: "договор поставки товара")
    let covered = try RawFixtures.insertText(db, hash: "h-done", content: "протокол осмотра места")
    try RawFixtures.insertVariant(db, documentId: "doc-a", textHash: "h-open")
    try RawFixtures.insertVariant(db, documentId: "doc-b", textHash: "h-done")

    try await store.registerEmbeddingModel(
        LocalEmbeddingDescriptor(providerId: "test", modelId: "vec-4", dimension: 4, maximumInputTokens: 32)
    )
    try await store.storeChunkEmbeddings(
        covered.map { ChunkEmbeddingBatchItem(chunkRowid: $0, embedding: VectorQuantizer.quantize([1, 0, 0, 0])) },
        modelId: "vec-4"
    )

    let created = try await store.enqueueEmbedJobs(in: .wholeCase(id: "case-a"), modelId: "vec-4", priority: 3)
    #expect(created == 1)
    let jobs = try await store.jobs(kind: .embed, states: [.queued])
    #expect(jobs.map(\.target) == [IndexJobRecord.textTarget("h-open")])
    #expect(jobs[0].modelId == "vec-4")
    #expect(jobs[0].priority == 3)
    #expect(uncovered.isEmpty == false)

    #expect(try await store.enqueueEmbedJobs(in: .wholeCase(id: "case-a"), modelId: "vec-4") == 0)
    #expect(try await store.jobs(kind: .embed).count == 1)
}

@Test("purgeFinishedJobs удаляет только старые done|failed")
func очисткаЗавершённыхЗадач() async throws {
    let temp = TemporaryDatabase()
    let store = try await temp.openWriter()
    let done = try await store.enqueueJob(kind: .extract, target: "doc:done")
    let failed = try await store.enqueueJob(kind: .extract, target: "doc:fail")
    let live = try await store.enqueueJob(kind: .extract, target: "doc:live")
    try await store.completeJob(id: done.id)
    let claimed = try await store.claimNextJobs(kind: .extract, limit: 1)
    #expect(claimed.map(\.id) == [failed.id])
    try await store.failJob(id: failed.id, error: "нет", requeue: false)

    #expect(try await store.purgeFinishedJobs(olderThan: Date.distantPast) == 0)
    let removed = try await store.purgeFinishedJobs(olderThan: Date.distantFuture)
    #expect(removed == 2)
    let remaining = try await store.jobs()
    #expect(remaining.map(\.id) == [live.id])
    #expect(try await store.jobCounts()[.queued] == 1)
}
