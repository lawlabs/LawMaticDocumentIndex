import Foundation
import Testing
@testable import LawMaticDocumentIndex

@Test("Сборка страниц идёт в физическом порядке и пересчитывает UTF-16")
func сборкаСтраницПересчитываетДиапазоны() {
    let pages = [
        ExtractionPageResult(pageNumber: 2, text: "вторая", status: .complete),
        ExtractionPageResult(pageNumber: 1, text: "первая", status: .complete),
    ]
    let assembled = ExtractionPageAssembler.assemble(pages: pages, pagesTotal: 2)
    #expect(assembled.status == .complete)
    #expect(assembled.processed == 2)
    #expect(assembled.text.hasPrefix("первая"))
    #expect(assembled.ranges.map(\.pageNumber) == [1, 2])
    #expect(assembled.ranges[0].utf16Start == 0)
    #expect(assembled.ranges[1].utf16Start == assembled.ranges[0].utf16End)
}

@Test("Страницы со статусом skipped не считаются извлечёнными")
func пропущенныеСтраницыНеДаютComplete() {
    let pages = [
        ExtractionPageResult(pageNumber: 1, text: "текст", status: .complete),
        ExtractionPageResult(pageNumber: 2, text: "", status: .skipped, errorCode: "ocr_disabled"),
        ExtractionPageResult(pageNumber: 3, text: "", status: .skipped, errorCode: "ocr_disabled"),
    ]
    let assembled = ExtractionPageAssembler.assemble(pages: pages, pagesTotal: 3)
    #expect(assembled.status == .partial)
    #expect(assembled.processed == 1)
}

@Test("Пустая успешно распознанная страница завершена и не ломает complete")
func пустаяСтраницаСчитаетсяЗавершённой() {
    let pages = [
        ExtractionPageResult(pageNumber: 1, text: "текст", status: .complete),
        ExtractionPageResult(pageNumber: 2, text: "", status: .noText),
    ]
    let assembled = ExtractionPageAssembler.assemble(pages: pages, pagesTotal: 2)
    #expect(assembled.status == .complete)
    #expect(assembled.processed == 2)
}

@Test("Смена hash или конфигурации не подставляет чужие страницы")
func страницаПривязанаКHashИКонфигурации() async throws {
    let fixture = try await ExtensionFixture.open()
    let document = try await fixture.store.upsertWorkspaceDocument(
        workspaceRootId: fixture.root.id,
        relativePath: "Дело/скан.pdf",
        fileSize: 10,
        fileModifiedAt: Date(),
        fileHash: "hash-a"
    )
    let configA = ExtractionPageAssembler.configId(
        extractorId: "pdf-page-pipeline",
        extractorVersion: 2,
        extras: ["ocr": "on", "limit": "2"]
    )
    let configB = ExtractionPageAssembler.configId(
        extractorId: "pdf-page-pipeline",
        extractorVersion: 2,
        extras: ["ocr": "off", "limit": "2"]
    )
    try await fixture.store.replaceExtractionPageResults(
        documentId: document.id,
        sourceFileHash: "hash-a",
        configId: configA,
        pages: [ExtractionPageResult(pageNumber: 1, text: "старая", status: .complete)]
    )
    #expect(try await fixture.store.extractionPageResults(
        documentId: document.id, sourceFileHash: "hash-b", configId: configA
    ).isEmpty)
    #expect(try await fixture.store.extractionPageResults(
        documentId: document.id, sourceFileHash: "hash-a", configId: configB
    ).isEmpty)
    #expect(try await fixture.store.extractionPageResults(
        documentId: document.id, sourceFileHash: "hash-a", configId: configA
    ).map(\.text) == ["старая"])
    await fixture.store.close()
}

@Test("Resume чужой OCR-конфигурации не подставляет страницы")
func resumeЧужойКонфигурацииПуст() {
    let pages = [1: ExtractionPageResult(pageNumber: 1, text: "из A", status: .complete)]
    let accepted = ExtractionPageResumePolicy.usableFinishedPages(
        resumeHash: "hash",
        resumeConfigId: "pdf-page-pipeline|2|limit=2;model=a;ocr=on;provider=apple",
        pages: pages,
        currentHash: "hash",
        currentConfigId: "pdf-page-pipeline|2|limit=2;model=b;ocr=on;provider=mistral"
    )
    #expect(accepted.isEmpty)
    let same = ExtractionPageResumePolicy.usableFinishedPages(
        resumeHash: "hash",
        resumeConfigId: "cfg-a",
        pages: pages,
        currentHash: "hash",
        currentConfigId: "cfg-a"
    )
    #expect(same[1]?.text == "из A")
}

@Test("Checkpoint страниц переживает прерванный прогон")
func checkpointСтраницПереживаетОтмену() async throws {
    let fixture = try await ExtensionFixture.open()
    let document = try await fixture.store.upsertWorkspaceDocument(
        workspaceRootId: fixture.root.id,
        relativePath: "Дело/скан.pdf",
        fileSize: 10,
        fileModifiedAt: Date(),
        fileHash: "hash-run"
    )
    let config = ExtractionPageAssembler.configId(
        extractorId: "pdf-page-pipeline",
        extractorVersion: 2,
        extras: ["ocr": "on", "limit": "5", "model": "vision", "provider": "apple"]
    )
    try await fixture.store.replaceExtractionPageResults(
        documentId: document.id,
        sourceFileHash: "hash-run",
        configId: config,
        pages: [
            ExtractionPageResult(pageNumber: 1, text: "стр1", status: .complete),
            ExtractionPageResult(pageNumber: 2, text: "стр2", status: .complete),
        ]
    )
    let saved = try await fixture.store.extractionPageResults(
        documentId: document.id, sourceFileHash: "hash-run", configId: config
    )
    #expect(saved.map(\.pageNumber) == [1, 2])
    try await fixture.store.upsertExtractionPageResult(
        documentId: document.id,
        sourceFileHash: "hash-run",
        configId: config,
        page: ExtractionPageResult(pageNumber: 3, text: "стр3", status: .complete)
    )
    let after = try await fixture.store.extractionPageResults(
        documentId: document.id, sourceFileHash: "hash-run", configId: config
    )
    #expect(after.map(\.text) == ["стр1", "стр2", "стр3"])
    await fixture.store.close()
}

@Test("Повтор обрабатывает только незавершённые страницы")
func повторБерётТолькоНезавершённыеСтраницы() {
    let previous = [
        ExtractionPageResult(pageNumber: 1, text: "ok", status: .complete),
        ExtractionPageResult(pageNumber: 2, text: "", status: .failed, errorCode: "ocr_failed"),
        ExtractionPageResult(pageNumber: 3, text: "", status: .noText),
    ]
    let retry = previous.filter { !$0.isFinished }.map(\.pageNumber)
    #expect(retry == [2])
    let after = [
        previous[0],
        ExtractionPageResult(pageNumber: 2, text: "восстановлено", status: .complete),
        previous[2],
    ]
    let assembled = ExtractionPageAssembler.assemble(pages: after, pagesTotal: 3)
    #expect(assembled.status == .complete)
    #expect(assembled.text.contains("восстановлено"))
}

private struct ExtensionFixture {
    let temp: TemporaryDatabase
    let store: DocumentIndexStore
    let root: WorkspaceRootRecord

    static func open() async throws -> ExtensionFixture {
        let temp = TemporaryDatabase()
        let store = try await temp.openWriter()
        let root = try await store.registerWorkspaceRoot(name: "Work", localPath: "/tmp/work")
        return ExtensionFixture(temp: temp, store: store, root: root)
    }
}
