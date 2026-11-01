import Foundation
import Testing
@testable import LawMaticDocumentIndex

@Test("Чанки сохраняют точные смещения исходного текста")
func чанкиСохраняютТочныеСмещенияИсходногоТекста() {
    let text = "  Первый абзац с кириллицей.\n\nВторой абзац содержит ещё несколько слов."
    let chunks = SearchChunker.chunks(from: text, targetWordCount: 5, overlapWordCount: 1)
    #expect(chunks.count >= 2, "текст разбит на несколько чанков")

    let nsText = text as NSString
    for chunk in chunks {
        let restored = nsText.substring(
            with: NSRange(
                location: chunk.utf16Start,
                length: chunk.utf16End - chunk.utf16Start
            )
        )
        #expect(restored == chunk.content, "чанк \(chunk.chunkIndex) восстанавливается по смещениям")
    }
    #expect(
        chunks[1].content.split(separator: " ").first.map(String.init) == "Второй",
        "последнее слово предыдущего чанка сохранено как перекрытие"
    )
}
