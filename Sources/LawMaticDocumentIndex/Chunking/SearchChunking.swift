import Foundation

/// Фрагмент исходного текста с точной привязкой к UTF-16 смещениям.
///
/// Смещения намеренно определены как UTF-16, а не как абстрактные «символы»:
/// ими пользуются `NSRange`, PDFKit и AppKit, и по ним можно без эвристики
/// дочитать либо подсветить исходный фрагмент.
public struct SearchChunkDraft: Equatable, Sendable {
    public let chunkIndex: Int
    public let utf16Start: Int
    public let utf16End: Int
    public let content: String

    public init(chunkIndex: Int, utf16Start: Int, utf16End: Int, content: String) {
        self.chunkIndex = chunkIndex
        self.utf16Start = utf16Start
        self.utf16End = utf16End
        self.content = content
    }
}

/// Детерминированная нарезка текста для лексического и семантического поиска.
///
/// Размер по умолчанию меньше прежних 500 слов. Системная contextual-модель
/// принимает не более 256 subword-токенов, поэтому Apple-провайдер обрабатывает
/// длинный чанк последовательными окнами и не теряет обрезанный хвост.
/// 180 слов — отправная точка, которую затем нужно подтвердить метриками.
public enum SearchChunker: Sendable {
    public static let defaultTargetWordCount = 180
    public static let defaultOverlapWordCount = 30

    public static func chunks(
        from text: String,
        targetWordCount: Int = defaultTargetWordCount,
        overlapWordCount: Int = defaultOverlapWordCount
    ) -> [SearchChunkDraft] {
        let target = max(targetWordCount, 1)
        let overlap = min(max(overlapWordCount, 0), target - 1)
        let nsText = text as NSString
        guard nsText.length > 0 else { return [] }

        let expression = try? NSRegularExpression(pattern: #"\S+"#)
        let wordRanges = expression?.matches(
            in: text,
            range: NSRange(location: 0, length: nsText.length)
        ).map(\.range) ?? []
        guard !wordRanges.isEmpty else { return [] }

        var result: [SearchChunkDraft] = []
        var startWord = 0

        while startWord < wordRanges.count {
            let endWord = min(startWord + target, wordRanges.count)
            let firstRange = wordRanges[startWord]
            let lastRange = wordRanges[endWord - 1]
            let start = firstRange.location
            let end = NSMaxRange(lastRange)
            let range = NSRange(location: start, length: end - start)

            result.append(
                SearchChunkDraft(
                    chunkIndex: result.count,
                    utf16Start: start,
                    utf16End: end,
                    content: nsText.substring(with: range)
                )
            )

            guard endWord < wordRanges.count else { break }
            startWord = endWord - overlap
        }

        return result
    }
}
