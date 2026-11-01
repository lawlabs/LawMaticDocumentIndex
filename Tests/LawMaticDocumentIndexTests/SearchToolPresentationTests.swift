import Foundation
import Testing
@testable import LawMaticDocumentIndex

@Test("Tool-выдача диверсифицирует документы и сокращает длинный текст")
func toolВыдачаДиверсифицируетДокументыИСокращаетДлинныйТекст() {
    func result(_ id: String, documentId: String) -> ChunkSearchResult {
        ChunkSearchResult(
            id: id,
            chunkId: id,
            documentId: documentId,
            fileURL: URL(fileURLWithPath: "/tmp/\(id).txt"),
            fileName: "\(id).txt",
            relativePath: "\(id).txt",
            variantType: "original",
            documentTextHash: nil,
            content: id,
            utf16Start: 0,
            utf16End: id.utf16.count,
            pageNumber: nil,
            score: 1,
            source: .lexical
        )
    }

    let contract200 = """
    Договор подряда. Цена работ составляет 200 000 рублей. Срок выполнения — 30 дней.
    Подрядчик обязуется выполнить работы качественно и в срок. Заказчик оплачивает
    работы после подписания акта. Ответственность сторон определяется законом.
    """
    let contract900 = """
    Договор подряда. Цена работ составляет 900 000 рублей. Срок выполнения — 30 дней.
    Подрядчик обязуется выполнить работы качественно и в срок. Заказчик оплачивает
    работы после подписания акта. Ответственность сторон определяется законом.
    """
    let differentSums = SearchToolPresentation.diversifiedResults(
        [
            ChunkSearchResult(
                id: "sum-200",
                chunkId: "sum-200",
                documentId: "contract-200",
                fileURL: URL(fileURLWithPath: "/tmp/c-200.txt"),
                fileName: "contract.txt",
                relativePath: "Client-1/contract.txt",
                variantType: "original",
                documentTextHash: "hash-200",
                content: contract200,
                utf16Start: 0,
                utf16End: contract200.utf16.count,
                pageNumber: nil,
                score: 1,
                source: .lexical
            ),
            ChunkSearchResult(
                id: "sum-900",
                chunkId: "sum-900",
                documentId: "contract-900",
                fileURL: URL(fileURLWithPath: "/tmp/c-900.txt"),
                fileName: "contract.txt",
                relativePath: "Client-2/contract.txt",
                variantType: "original",
                documentTextHash: "hash-900",
                content: contract900,
                utf16Start: 0,
                utf16End: contract900.utf16.count,
                pageNumber: nil,
                score: 0.95,
                source: .lexical
            )
        ],
        limit: 2
    )
    #expect(
        Set(differentSums.map(\.documentId)) == ["contract-200", "contract-900"],
        "разные суммы не склеиваются как почти одинаковые копии"
    )
    #expect(
        SearchToolPresentation.additionalCopyPaths(of: differentSums[0], in: differentSums).isEmpty
    )

    let diversified = SearchToolPresentation.diversifiedResults(
        [
            result("a-1", documentId: "a"),
            result("a-2", documentId: "a"),
            result("a-3", documentId: "a"),
            result("b-1", documentId: "b"),
            result("c-1", documentId: "c")
        ],
        limit: 4
    )
    #expect(
        diversified.map(\.chunkId) == ["a-1", "b-1", "c-1"],
        "выдаётся не больше одного фрагмента каждого документа"
    )

    let commonText = """
    Протокол заседания правления общества. Председатель Зименков Игорь
    Владимирович открыл заседание, сообщил повестку и результаты голосования.
    """
    let copied = SearchToolPresentation.diversifiedResults(
        [
            ChunkSearchResult(
                id: "copy-a",
                chunkId: "copy-a",
                documentId: "copy-document-a",
                fileURL: URL(fileURLWithPath: "/tmp/copy-a.pdf"),
                fileName: "copy-a.pdf",
                relativePath: "copy-a.pdf",
                variantType: "original",
                documentTextHash: "same-document-text",
                content: commonText,
                utf16Start: 0,
                utf16End: commonText.utf16.count,
                pageNumber: 1,
                score: 1,
                source: .lexical
            ),
            ChunkSearchResult(
                id: "copy-b",
                chunkId: "copy-b",
                documentId: "copy-document-b",
                fileURL: URL(fileURLWithPath: "/tmp/copy-b.pdf"),
                fileName: "copy-b.pdf",
                relativePath: "copy-b.pdf",
                variantType: "original",
                documentTextHash: "same-document-text",
                content: commonText + " Копия.",
                utf16Start: 0,
                utf16End: (commonText + " Копия.").utf16.count,
                pageNumber: 1,
                score: 0.9,
                source: .lexical
            ),
            result("different", documentId: "different-document")
        ],
        limit: 3
    )
    #expect(
        copied.map(\.chunkId) == ["copy-a", "different"],
        "почти одинаковые копии текста не занимают несколько мест выдачи"
    )

    let exactHashCopies = SearchToolPresentation.diversifiedResults(
        [
            ChunkSearchResult(
                id: "pdf-copy",
                chunkId: "pdf-copy",
                documentId: "pdf-document",
                fileURL: URL(fileURLWithPath: "/tmp/document.pdf"),
                fileName: "document.pdf",
                relativePath: "document.pdf",
                variantType: "original",
                documentTextHash: "full-text-hash",
                content: "Начало документа и первый релевантный фрагмент.",
                utf16Start: 0,
                utf16End: 52,
                pageNumber: 1,
                score: 1,
                source: .lexical
            ),
            ChunkSearchResult(
                id: "attachment-copy",
                chunkId: "attachment-copy",
                documentId: "attachment-document",
                fileURL: URL(fileURLWithPath: "/tmp/attachment.bin"),
                fileName: "attachment.bin",
                relativePath: "attachment.bin",
                variantType: "original",
                documentTextHash: "full-text-hash",
                content: "Другой участок той же копии, попавший в выдачу.",
                utf16Start: 100,
                utf16End: 147,
                pageNumber: nil,
                score: 0.9,
                source: .semantic
            )
        ],
        limit: 2
    )
    #expect(
        exactHashCopies.map(\.chunkId) == ["pdf-copy"],
        "одинаковый полный текст склеивает разные контейнеры до показа фрагментов"
    )

    let sameDocument = SearchToolPresentation.diversifiedResults(
        [
            ChunkSearchResult(
                id: "same-1",
                chunkId: "same-1",
                documentId: "same-document",
                fileURL: URL(fileURLWithPath: "/tmp/same.pdf"),
                fileName: "same.pdf",
                relativePath: "same.pdf",
                variantType: "original",
                documentTextHash: "same-hash",
                content: "Первый самостоятельный раздел документа.",
                utf16Start: 0,
                utf16End: 40,
                pageNumber: 1,
                score: 1,
                source: .lexical
            ),
            ChunkSearchResult(
                id: "same-2",
                chunkId: "same-2",
                documentId: "same-document",
                fileURL: URL(fileURLWithPath: "/tmp/same.pdf"),
                fileName: "same.pdf",
                relativePath: "same.pdf",
                variantType: "original",
                documentTextHash: "same-hash",
                content: "Второй независимый раздел с иными обстоятельствами.",
                utf16Start: 500,
                utf16End: 550,
                pageNumber: 3,
                score: 0.8,
                source: .lexical
            )
        ],
        limit: 2
    )
    #expect(
        sameDocument.map(\.chunkId) == ["same-1"],
        "второй фрагмент того же документа дочитывается только адресным tool"
    )

    let protocolWords = (1...45).map { "пункт\($0)" }
    let originalProtocol = protocolWords.joined(separator: " ")
    var ocrWords = protocolWords
    ocrWords[8] = "ошибкараспознавания"
    ocrWords[27] = "исправлено"
    let ocrProtocol = ocrWords.joined(separator: " ")
    let ocrCopies = SearchToolPresentation.diversifiedResults(
        [
            ChunkSearchResult(
                id: "protocol-pdf",
                chunkId: "protocol-pdf",
                documentId: "protocol-pdf-document",
                fileURL: URL(fileURLWithPath: "/tmp/protocol.pdf"),
                fileName: "protocol.pdf",
                relativePath: "protocol.pdf",
                variantType: "original",
                documentTextHash: "pdf-hash",
                content: originalProtocol,
                utf16Start: 0,
                utf16End: originalProtocol.utf16.count,
                pageNumber: 1,
                score: 1,
                source: .lexical
            ),
            ChunkSearchResult(
                id: "protocol-photo",
                chunkId: "protocol-photo",
                documentId: "protocol-photo-document",
                fileURL: URL(fileURLWithPath: "/tmp/protocol.jpg"),
                fileName: "protocol.jpg",
                relativePath: "protocol.jpg",
                variantType: "original",
                documentTextHash: "ocr-hash",
                content: ocrProtocol,
                utf16Start: 0,
                utf16End: ocrProtocol.utf16.count,
                pageNumber: nil,
                score: 0.9,
                source: .lexical
            )
        ],
        limit: 2
    )
    #expect(
        ocrCopies.map(\.chunkId) == ["protocol-pdf"],
        "локальный fuzzy-профиль склеивает PDF и OCR-фото с мелкими ошибками"
    )

    let embeddedText = (["вводная", "часть"] + protocolWords + ["конец", "приложения"])
        .joined(separator: " ")
    let embeddedCopies = SearchToolPresentation.diversifiedResults(
        [
            ChunkSearchResult(
                id: "standalone-protocol",
                chunkId: "standalone-protocol",
                documentId: "standalone-document",
                fileURL: URL(fileURLWithPath: "/tmp/standalone.pdf"),
                fileName: "standalone.pdf",
                relativePath: "standalone.pdf",
                variantType: "original",
                documentTextHash: "standalone-hash",
                content: originalProtocol,
                utf16Start: 0,
                utf16End: originalProtocol.utf16.count,
                pageNumber: 1,
                score: 1,
                source: .lexical
            ),
            ChunkSearchResult(
                id: "case-materials-protocol",
                chunkId: "case-materials-protocol",
                documentId: "case-materials-document",
                fileURL: URL(fileURLWithPath: "/tmp/materials.pdf"),
                fileName: "materials.pdf",
                relativePath: "materials.pdf",
                variantType: "original",
                documentTextHash: "materials-hash",
                content: embeddedText,
                utf16Start: 900,
                utf16End: 900 + embeddedText.utf16.count,
                pageNumber: 14,
                score: 0.8,
                source: .hybrid
            )
        ],
        limit: 2
    )
    #expect(
        embeddedCopies.map(\.chunkId) == ["standalone-protocol"],
        "последовательности слов склеивают отдельный документ и его вложение в сборник"
    )

    let longText = String(repeating: "начало ", count: 120)
        + "ПРЕДСЕДАТЕЛЬ ПРАВЛЕНИЯ"
        + String(repeating: " конец", count: 120)
    let snippet = SearchToolPresentation.compactSnippet(
        content: longText,
        query: "председатель правления",
        maxCharacters: 180
    )
    #expect(snippet.localizedCaseInsensitiveContains("председатель правления"), "сниппет сохраняет совпадение")
    #expect(snippet.count <= 182, "сниппет ограничен вместе с многоточиями")
    #expect(snippet.hasPrefix("…") && snippet.hasSuffix("…"), "обрезание обозначено с обеих сторон")
}

@Test("Похожие договоры с разными суммами не склеиваются")
func разныеСуммыНеСклеиваютсяКакКопии() {
    func hit(id: String, hash: String, amount: String) -> ChunkSearchResult {
        let text = """
        Договор подряда. Цена работ составляет \(amount) рублей. Срок выполнения — 30 дней.
        Подрядчик обязуется выполнить работы качественно и в срок. Заказчик оплачивает
        работы после подписания акта. Ответственность сторон определяется законом.
        """
        return ChunkSearchResult(
            id: id,
            chunkId: id,
            documentId: id,
            fileURL: URL(fileURLWithPath: "/tmp/\(id).txt"),
            fileName: "contract.txt",
            relativePath: "\(id)/contract.txt",
            variantType: "original",
            documentTextHash: hash,
            content: text,
            utf16Start: 0,
            utf16End: text.utf16.count,
            pageNumber: nil,
            score: 1,
            source: .lexical
        )
    }
    let hits = [hit(id: "c200", hash: "h200", amount: "200 000"), hit(id: "c900", hash: "h900", amount: "900 000")]
    let diversified = SearchToolPresentation.diversifiedResults(hits, limit: 2)
    #expect(Set(diversified.map(\.documentId)) == ["c200", "c900"])
    #expect(SearchToolPresentation.additionalCopyPaths(of: hits[0], in: hits).isEmpty)
}
