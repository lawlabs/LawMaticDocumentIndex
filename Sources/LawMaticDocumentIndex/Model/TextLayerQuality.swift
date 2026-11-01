import Foundation

/// Годится ли текстовый слой PDF для поиска.
///
/// Бывает, что скан уже «распознан» чужой программой, но не тем языком:
/// русские буквы записаны похожими латинскими — «yilPABA PAMOHA KOHbKOBO»
/// вместо «УПРАВА РАЙОНА КОНЬКОВО». Слой непустой, поэтому OCR страницу не
/// трогал, а поиск по такому тексту не находит ничего. В деле так лежали все
/// распоряжения управы и протоколы правления.
///
/// Признаки такого слоя — сразу все:
/// - букв на странице достаточно, чтобы судить (не штамп и не номер);
/// - латиница — не меньше половины букв;
/// - это не английский текст: служебных слов английского («the», «of», «and»)
///   почти нет;
/// - регистр «рваный» внутри слов: «PACnOPOEHHE», «corjiacoBano», «K)ro-3ana4Hbiw».
///   В настоящем латинском тексте так пишутся разве что «iPhone» и «McDonald»;
///   в банковских реквизитах (IBAN, SWIFT) слова целиком заглавные.
public enum TextLayerQuality {
    public struct Assessment: Equatable, Sendable {
        /// Букв латиницы и кириллицы.
        public let letters: Int
        public let latinShare: Double
        /// Латинских слов от двух знаков.
        public let latinWords: Int
        /// Доля служебных слов английского среди латинских слов.
        public let englishFunctionWordShare: Double
        /// Доля латинских слов с «рваным» регистром или цифрой внутри.
        public let brokenWordShare: Double

        public var isGarbled: Bool {
            letters >= TextLayerQuality.minimumLetters
                && latinWords >= TextLayerQuality.minimumWords
                && latinShare >= 0.5
                && englishFunctionWordShare < 0.05
                && brokenWordShare >= 0.15
        }
    }

    static let minimumLetters = 40
    static let minimumWords = 8

    public static func isGarbled(_ text: String) -> Bool {
        assess(text).isGarbled
    }

    public static func assess(_ text: String) -> Assessment {
        var latin = 0
        var cyrillic = 0
        var words = 0
        var functionWords = 0
        var broken = 0

        func finish(_ word: Substring) {
            guard word.count >= 2, word.contains(where: isLatinLetter) else { return }
            words += 1
            if englishFunctionWords.contains(word.lowercased()) { functionWords += 1 }
            if isBroken(word) { broken += 1 }
        }

        var wordStart: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if isLatinLetter(character) {
                latin += 1
            } else if isCyrillicLetter(character) {
                cyrillic += 1
            }
            // Слово — латиница и цифры подряд, вместе с ними «)» и «^»: в таком
            // слое ими часто записаны «Ю» и «Д» («K)ro», «FOPO^A»).
            let isWordCharacter = isLatinLetter(character) || character.isNumber || character == ")" || character == "^"
            if isWordCharacter {
                if wordStart == nil { wordStart = index }
            } else if let start = wordStart {
                finish(text[start..<index])
                wordStart = nil
            }
            index = text.index(after: index)
        }
        if let start = wordStart { finish(text[start...]) }

        let letters = latin + cyrillic
        return Assessment(
            letters: letters,
            latinShare: letters == 0 ? 0 : Double(latin) / Double(letters),
            latinWords: words,
            englishFunctionWordShare: words == 0 ? 0 : Double(functionWords) / Double(words),
            brokenWordShare: words == 0 ? 0 : Double(broken) / Double(words)
        )
    }

    /// «yilPABA», «corjiacoBano» — строчная перед заглавной; «PACnOPOEHHE» —
    /// заглавные, строчные и снова заглавная; «ana4Hbiw» — цифра внутри букв.
    static func isBroken(_ word: Substring) -> Bool {
        let characters = Array(word)
        var sawUpperRun = 0
        var sawLowerAfterUpperRun = false
        for (offset, character) in characters.enumerated() {
            if offset > 0 {
                let previous = characters[offset - 1]
                if previous.isLowercase && character.isUppercase && isLatinLetter(previous) && isLatinLetter(character) {
                    return true
                }
                if character.isNumber, isLatinLetter(previous),
                   offset + 1 < characters.count, isLatinLetter(characters[offset + 1]) {
                    return true
                }
            }
            if character.isUppercase {
                if sawLowerAfterUpperRun { return true }
                sawUpperRun += 1
            } else if character.isLowercase {
                if sawUpperRun >= 2 { sawLowerAfterUpperRun = true }
            }
        }
        return false
    }

    private static func isLatinLetter(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else { return false }
        return ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    }

    private static func isCyrillicLetter(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        return (0x0400...0x04FF).contains(scalar.value)
    }

    /// Самые частые служебные слова английского: в любом связном английском
    /// тексте их не меньше пятой части слов. Без «no» и «to»: так в мусорном
    /// слое выглядят русские «по» и «то».
    private static let englishFunctionWords: Set<String> = [
        "the", "of", "and", "in", "is", "that", "for", "on", "with", "as", "by", "be",
        "this", "are", "or", "at", "from", "an", "it", "its", "not", "which", "will", "shall",
        "may", "any", "such", "has", "have", "been", "was", "were", "all", "if", "under",
        "into", "other", "their", "these", "those", "than", "upon", "per", "each", "between"
    ]
}
