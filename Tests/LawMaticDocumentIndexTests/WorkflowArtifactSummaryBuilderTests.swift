import Foundation
import Testing
@testable import LawMaticDocumentIndex

@Test("Межходовой evidence-summary сохраняет адрес и проверенный текст")
func межходовойEvidenceSummaryСохраняетАдресИПроверенныйТекст() throws {
    func json(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    let search = try WorkflowArtifactSummaryBuilder.summary(
        toolName: "search_case_documents",
        normalizedResult: json([
            "ok": true,
            "query": "председатель правления",
            "returnedCount": 4,
            "results": [
                ["fileName": "Протокол №9.docx", "chunkId": "protocol-9:1"],
                ["fileName": "Протокол №1.pdf", "chunkId": "protocol-1:0"],
                ["fileName": "Договор.docx", "chunkId": "contract:44"],
                ["fileName": "Четвёртый.docx", "chunkId": "fourth:0"]
            ]
        ])
    )
    #expect(search.contains("4 результатов"), "search-summary сохраняет число результатов")
    #expect(search.contains("Протокол №9.docx [chunkId=protocol-9:1]"), "search-summary сохраняет адрес первого результата")
    #expect(search.contains("Договор.docx [chunkId=contract:44]"), "search-summary сохраняет до трёх адресных результатов")
    #expect(!search.contains("Четвёртый.docx"), "search-summary не раздувается четвёртым результатом")

    let verifiedText = """
    ПРЕДЛОЖЕНО: Избрать на один год Председателем Правления
    ТСН «Дом на Ефремова» Зименкова Игоря Владимировича.
    РЕШИЛИ: Избрать на один год.
    """
    let read = try WorkflowArtifactSummaryBuilder.summary(
        toolName: "read_document_chunk",
        normalizedResult: json([
            "ok": true,
            "chunkId": "protocol-9:1",
            "count": 2,
            "results": [
                [
                    "chunkId": "protocol-9:0",
                    "fileName": "Протокол №9.docx",
                    "content": "Соседний вводный фрагмент без решения."
                ],
                [
                    "chunkId": "protocol-9:1",
                    "fileName": "Протокол №9.docx",
                    "content": verifiedText
                ]
            ]
        ])
    )
    #expect(read.contains("chunkId=protocol-9:1"), "read-summary сохраняет chunkId для повторного чтения")
    #expect(read.contains("файл=Протокол №9.docx"), "read-summary сохраняет имя источника")
    #expect(read.contains("ПРЕДЛОЖЕНО: Избрать на один год"), "read-summary берёт anchor, а не первый соседний chunk")
    #expect(!read.contains("Соседний вводный"), "соседний chunk не выдаётся за проверенное доказательство")

    let longEvidence = String(repeating: "начало ", count: 150)
        + "середина "
        + String(repeating: "конец ", count: 150)
    let compact = try WorkflowArtifactSummaryBuilder.summary(
        toolName: "read_document_chunk",
        normalizedResult: json([
            "ok": true,
            "chunkId": "long:0",
            "count": 1,
            "results": [[
                "chunkId": "long:0",
                "fileName": "Большой.pdf",
                "content": longEvidence
            ]]
        ])
    )
    #expect(compact.contains(" … "), "длинное доказательство явно сокращается")
    #expect(compact.contains("начало") && compact.contains("конец"), "при сокращении сохраняются обе стороны anchor")
    #expect(compact.count < 900, "evidence-summary остаётся компактным")
}

@Test("UI-проекция tool-result не публикует полный текст чтения")
func uiПроекцияToolResultНеПубликуетПолныйТекстЧтения() throws {
    let anchorText = String(repeating: "доказательство ", count: 1_000)
    let rawData = try JSONSerialization.data(withJSONObject: [
        "ok": true,
        "chunkId": "large:0",
        "count": 4,
        "results": [
            [
                "chunkId": "large:0",
                "fileName": "Большой иск.docx",
                "content": anchorText
            ],
            [
                "chunkId": "large:1",
                "fileName": "Большой иск.docx",
                "content": String(repeating: "соседний текст ", count: 1_000)
            ]
        ]
    ])
    let rawResult = String(decoding: rawData, as: UTF8.self)
    let presented = ToolResultUIPresentation.compactResult(
        toolName: "read_document_chunk",
        rawResult: rawResult
    )

    #expect(rawResult.count > 20_000, "регрессия воспроизводит большой сырой tool-result")
    #expect(presented.count < 1_000, "UI получает компактный result вместо полного JSON")
    #expect(presented.contains("chunkId=large:0"), "UI-summary сохраняет адрес доказательства")
    #expect(presented.contains("Большой иск.docx"), "UI-summary сохраняет имя документа")
    #expect(presented != rawResult, "сокращение не изменяет исходный result для LLM")
}
