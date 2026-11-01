import Foundation

/// Морфологическая нормализация русского текста для полнотекстового поиска.
///
/// Индекс и запрос проходят одну и ту же нормализацию, поэтому «неосновательного»
/// и «неосновательное» сводятся к общей основе и находят друг друга. Без этого
/// FTS5 с токенизатором `unicode61` сравнивает словоформы буквально, и запрос на
/// естественном языке почти всегда возвращает пустую выдачу.
public enum RussianTextNormalizer: Sendable {

    /// Нормализованный текст для записи в поисковый индекс.
    public static func normalizeForIndex(_ text: String) -> String {
        var cache: [String: String] = [:]
        var result: [String] = []
        result.reserveCapacity(text.count / 6)

        enumerateTokens(in: text) { token, _ in
            result.append(normalizeToken(token, cache: &cache))
            return true
        }

        result.append(contentsOf: dateTokens(in: text))
        return result.joined(separator: " ")
    }

    /// Нормализованные токены запроса в порядке появления, без повторов.
    ///
    /// Служебные слова отбрасываются. Юрист спрашивает предложением — «Куда
    /// делись деньги по договору уступки к РН+?» — и строгая ступень поиска
    /// требовала присутствия в документе слов «куда», «по» и «к». Ни один договор
    /// так не найдётся. Из **индекса** такие слова не убираются: они нужны для
    /// поиска точных фраз.
    public static func queryStems(from query: String) -> [String] {
        var cache: [String: String] = [:]
        var seen: Set<String> = []
        var stems: [String] = []
        var dropped: [String] = []

        // Числа, из которых состоит распознанная дата, в запрос не попадают:
        // их смысл уже несёт канонический токен. Иначе «31.10.2022» требовало бы
        // от документа ещё и токен «10», которого нет в записи «31 октября 2022»,
        // и строгая ступень не находила бы нужный документ.
        let dateRanges = dateCharacterRanges(in: query)

        enumerateTokens(in: query) { token, range in
            if dateRanges.contains(where: { $0.contains(range.lowerBound) }) { return true }
            let stem = normalizeToken(token, cache: &cache)
            guard !stem.isEmpty, seen.insert(stem).inserted else { return true }
            if stopWordStems.contains(stem) {
                dropped.append(stem)
            } else {
                stems.append(stem)
            }
            return true
        }

        for token in dateTokens(in: query) where seen.insert(token).inserted {
            stems.append(token)
        }

        // Запрос целиком из служебных слов — ищем как есть, иначе выдача пуста
        // на пустом месте.
        return stems.isEmpty ? dropped : stems
    }

    // MARK: - Даты

    /// Канонические токены дат, найденных в тексте.
    ///
    /// Дата в юридическом документе — сильнейший различающий признак, но при
    /// обычной токенизации «31.10.2022» распадается на «31», «10» и «2022».
    /// Эти числа встречаются повсеместно, различительной силы почти не несут, и
    /// запрос «что решили на ОСС 31.10.2022» тонул среди документов, где просто
    /// упоминается 2022 год. Отдельный токен вида `дата20221031` делает дату
    /// точным условием. Обычные числовые токены при этом сохраняются, поэтому
    /// поиск по «2022» продолжает работать.
    public static func dateTokens(in text: String) -> [String] {
        var tokens: Set<String> = []

        let numeric = Self.numericDateRegex
        let full = NSRange(text.startIndex..<text.endIndex, in: text)

        numeric.enumerateMatches(in: text, options: [], range: full) { match, _, _ in
            guard let match,
                  let day = match.group(1, in: text),
                  let month = match.group(2, in: text),
                  let year = match.group(3, in: text) else { return }
            if let token = canonicalDate(day: day, month: month, year: year) {
                tokens.insert(token)
            }
        }

        Self.textualDateRegex.enumerateMatches(in: text, options: [], range: full) { match, _, _ in
            guard let match,
                  let day = match.group(1, in: text),
                  let monthName = match.group(2, in: text)?.lowercased(),
                  let year = match.group(3, in: text),
                  let month = Self.monthNumbers[String(monthName.prefix(3))] else { return }
            if let token = canonicalDate(day: day, month: String(month), year: year) {
                tokens.insert(token)
            }
        }

        return tokens.sorted()
    }

    /// Участки текста, занятые распознанными датами.
    ///
    /// Нужны только для запроса: из индекса числа не убираются, поиск по одному
    /// «2022» должен продолжать работать.
    private static func dateCharacterRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        let full = NSRange(text.startIndex..<text.endIndex, in: text)

        for regex in [Self.numericDateRegex, Self.textualDateRegex] {
            regex.enumerateMatches(in: text, options: [], range: full) { match, _, _ in
                guard let match, let range = Range(match.range, in: text) else { return }
                ranges.append(range)
            }
        }
        return ranges
    }

    private static func canonicalDate(day: String, month: String, year: String) -> String? {
        guard let dayValue = Int(day), (1...31).contains(dayValue),
              let monthValue = Int(month), (1...12).contains(monthValue),
              var yearValue = Int(year) else { return nil }

        // Двузначный год: документы в работе — это 2000-е.
        if year.count == 2 { yearValue += 2000 }
        guard (1900...2100).contains(yearValue) else { return nil }

        return String(format: "дата%04d%02d%02d", yearValue, monthValue, dayValue)
    }

    private static let numericDateRegex = try! NSRegularExpression(
        pattern: "\\b(\\d{1,2})[.\\-/](\\d{1,2})[.\\-/](\\d{4}|\\d{2})\\b"
    )

    private static let textualDateRegex = try! NSRegularExpression(
        pattern: "\\b(\\d{1,2})\\s+([А-Яа-яЁё]{3,10})\\s+(\\d{4})",
        options: [.caseInsensitive]
    )

    /// Первые три буквы месяца достаточно различают названия во всех падежах.
    private static let monthNumbers: [String: Int] = [
        "янв": 1, "фев": 2, "мар": 3, "апр": 4, "мая": 5, "май": 5, "июн": 6,
        "июл": 7, "авг": 8, "сен": 9, "окт": 10, "ноя": 11, "дек": 12
    ]

    /// Основы служебных слов: вопросительные, местоимения, предлоги, союзы,
    /// связки. Список намеренно короткий — значимые для юриста слова вроде
    /// «дело», «срок», «право» в него не входят.
    private static let stopWordStems: Set<String> = [
        // вопросительные
        "что", "кто", "где", "когд", "куд", "как", "скольк", "чей", "чем", "зач",
        "почему", "ли",
        // местоимения и определительные
        "я", "ты", "он", "она", "он", "мы", "вы", "их", "его", "ее", "нас", "вас",
        "наш", "ваш", "сво", "себ", "это", "этот", "тот", "так", "весь", "все",
        "котор", "нибуд",
        // предлоги
        "в", "во", "на", "по", "с", "со", "к", "ко", "у", "о", "об", "обо", "из",
        "за", "при", "до", "над", "под", "про", "для", "от", "без", "через",
        "между",
        // союзы и частицы
        "и", "а", "но", "или", "же", "бы", "не", "ни", "да", "то", "ж",
        // связки
        "быт", "был", "ест", "стал"
    ]

    /// Приводит один токен к поисковой основе.
    ///
    /// Токены без кириллицы (номера, латиница, даты) только приводятся к нижнему
    /// регистру: стеммер к ним неприменим, а их точная форма для юриста значима.
    public static func normalizeToken(_ token: String) -> String {
        var cache: [String: String] = [:]
        return normalizeToken(token, cache: &cache)
    }

    private static func normalizeToken(_ token: String, cache: inout [String: String]) -> String {
        if let cached = cache[token] { return cached }

        let lowered = token.lowercased().replacingOccurrences(of: "ё", with: "е")
        let normalized: String
        if lowered.unicodeScalars.allSatisfy({ cyrillicLetters.contains($0) }) {
            normalized = RussianStemmer.stem(lowered)
        } else {
            normalized = lowered
        }

        cache[token] = normalized
        return normalized
    }

    // MARK: - Сниппеты

    /// Строит фрагмент вокруг первого совпадения, подсвечивая найденные словоформы.
    ///
    /// Сниппет собирается из **оригинального** текста, а не из нормализованного:
    /// пользователь должен видеть «договора поставки», а не «договор поставк».
    public static func snippet(
        from text: String,
        matching stems: [String],
        radius: Int = 110,
        scanLimit: Int = 120_000
    ) -> String {
        guard !stems.isEmpty, !text.isEmpty else {
            return String(text.prefix(radius * 2))
        }

        let wanted = Set(stems)
        var cache: [String: String] = [:]
        var matches: [Range<String.Index>] = []
        var firstMatch: Range<String.Index>?
        var windowEnd: String.Index?

        let scanned = text.count > scanLimit ? String(text.prefix(scanLimit)) : text

        // Разбор прекращается сразу за окном вокруг первого совпадения: строить
        // сниппет нужно только по нему, а нормализация каждого токена по всему
        // документу превращала выдачу из двух сотен результатов в секунды работы.
        enumerateTokens(in: scanned) { token, range in
            if let windowEnd, range.lowerBound > windowEnd { return false }
            guard wanted.contains(normalizeToken(token, cache: &cache)) else { return true }
            if firstMatch == nil {
                firstMatch = range
                windowEnd = scanned.index(range.upperBound, offsetBy: radius, limitedBy: scanned.endIndex)
                    ?? scanned.endIndex
            }
            matches.append(range)
            return true
        }

        guard let anchor = firstMatch else {
            return String(text.prefix(radius * 2)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let lower = scanned.index(anchor.lowerBound, offsetBy: -radius, limitedBy: scanned.startIndex)
            ?? scanned.startIndex
        let upper = scanned.index(anchor.upperBound, offsetBy: radius, limitedBy: scanned.endIndex)
            ?? scanned.endIndex

        var pieces: [String] = []
        var cursor = lower
        for match in matches where match.lowerBound >= lower && match.upperBound <= upper {
            guard match.lowerBound >= cursor else { continue }
            pieces.append(String(scanned[cursor..<match.lowerBound]))
            pieces.append("[" + scanned[match] + "]")
            cursor = match.upperBound
        }
        pieces.append(String(scanned[cursor..<upper]))

        var snippet = pieces.joined()
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        while snippet.contains("  ") {
            snippet = snippet.replacingOccurrences(of: "  ", with: " ")
        }
        snippet = snippet.trimmingCharacters(in: .whitespacesAndNewlines)

        if lower > scanned.startIndex { snippet = "… " + snippet }
        if upper < scanned.endIndex { snippet += " …" }
        return snippet
    }

    // MARK: - Токенизация

    /// Разбивает текст так же, как это делает токенизатор `unicode61`: по границам
    /// букв и цифр. Согласованность с FTS5 обязательна — иначе запрос и индекс
    /// начнут расходиться на дефисах, номерах дел и датах.
    /// Замыкание возвращает `false`, чтобы прекратить разбор.
    private static func enumerateTokens(
        in text: String,
        _ body: (String, Range<String.Index>) -> Bool
    ) {
        var start: String.Index?
        var index = text.startIndex

        while index < text.endIndex {
            let isTokenCharacter = text[index].isLetter || text[index].isNumber
            if isTokenCharacter {
                if start == nil { start = index }
            } else if let tokenStart = start {
                if !body(String(text[tokenStart..<index]), tokenStart..<index) { return }
                start = nil
            }
            index = text.index(after: index)
        }

        if let tokenStart = start {
            _ = body(String(text[tokenStart..<text.endIndex]), tokenStart..<text.endIndex)
        }
    }

    private static let cyrillicLetters: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "а"..."я")
        set.insert(charactersIn: "А"..."Я")
        set.insert("ё")
        set.insert("Ё")
        return set
    }()
}

// MARK: - Стеммер

/// Стеммер Портера для русского языка (алгоритм Snowball).
///
/// Реализован целиком, чтобы не тащить зависимость ради одной функции. Порядок
/// шагов и наборы окончаний соответствуют эталонному описанию алгоритма.
private enum RussianStemmer {

    static func stem(_ word: String) -> String {
        var characters = Array(word)
        guard characters.count > 2 else { return word }

        let (rv, r2) = regions(characters)

        // Шаг 1: деепричастие, иначе возвратная частица + прилагательное/глагол/существительное.
        if !removePerfectiveGerund(&characters, rv) {
            _ = remove(&characters, endings: reflexive, from: rv)
            if !removeAdjectival(&characters, rv) {
                if !removeVerb(&characters, rv) {
                    _ = remove(&characters, endings: noun, from: rv)
                }
            }
        }

        // Шаг 2: завершающее «и».
        if characters.last == "и", characters.count - 1 >= rv {
            characters.removeLast()
        }

        // Шаг 3: словообразовательный суффикс в R2.
        _ = remove(&characters, endings: derivational, from: r2)

        // Шаг 4: удвоенное «н», превосходная степень, мягкий знак.
        if endsWithDoubleN(characters) {
            characters.removeLast()
        } else if remove(&characters, endings: superlative, from: rv) {
            if endsWithDoubleN(characters) { characters.removeLast() }
        } else if characters.last == "ь" {
            characters.removeLast()
        }

        collapseFleetingE(&characters)
        return String(characters)
    }

    // MARK: Регионы

    private static func regions(_ word: [Character]) -> (rv: Int, r2: Int) {
        var rv = word.count
        for index in word.indices where isVowel(word[index]) {
            rv = index + 1
            break
        }

        var r1 = word.count
        var index = 1
        while index < word.count {
            if !isVowel(word[index]), isVowel(word[index - 1]) {
                r1 = index + 1
                break
            }
            index += 1
        }

        var r2 = word.count
        index = r1 + 1
        while index < word.count {
            if !isVowel(word[index]), isVowel(word[index - 1]) {
                r2 = index + 1
                break
            }
            index += 1
        }

        return (rv, r2)
    }

    private static func isVowel(_ character: Character) -> Bool {
        vowels.contains(character)
    }

    private static func endsWithDoubleN(_ word: [Character]) -> Bool {
        word.count >= 2 && word[word.count - 2] == "н" && word[word.count - 1] == "н"
    }

    /// Сводит беглую «е» в суффиксе `-ец`: «истец» → «истц», как «истцом» → «истц».
    ///
    /// Алгоритм Snowball беглые гласные не обрабатывает, и в юридическом тексте это
    /// бьёт по самым частым словам — истец, ответчик-контрагент, продавец, поставщик.
    /// Правило намеренно узкое: только финальное «ец» и только если основа длиннее
    /// трёх букв, иначе пострадают «отец» и другие короткие корни.
    private static func collapseFleetingE(_ word: inout [Character]) {
        guard word.count > 3 else { return }
        guard word[word.count - 2] == "е", word[word.count - 1] == "ц" else { return }
        word.remove(at: word.count - 2)
    }

    // MARK: Удаление окончаний

    /// Удаляет первое подошедшее окончание, если оно целиком лежит в регионе.
    @discardableResult
    private static func remove(_ word: inout [Character], endings: [[Character]], from region: Int) -> Bool {
        for ending in endings {
            let start = word.count - ending.count
            guard start >= region, start >= 0 else { continue }
            guard Array(word[start...]) == ending else { continue }
            word.removeLast(ending.count)
            return true
        }
        return false
    }

    /// Вариант для окончаний, которым обязана предшествовать «а» или «я».
    private static func removePrecededByAYa(
        _ word: inout [Character],
        endings: [[Character]],
        from region: Int
    ) -> Bool {
        for ending in endings {
            let start = word.count - ending.count
            guard start >= region, start >= 1 else { continue }
            guard Array(word[start...]) == ending else { continue }
            let preceding = word[start - 1]
            guard preceding == "а" || preceding == "я" else { continue }
            word.removeLast(ending.count)
            return true
        }
        return false
    }

    private static func removePerfectiveGerund(_ word: inout [Character], _ rv: Int) -> Bool {
        if removePrecededByAYa(&word, endings: perfectiveGerundGroup1, from: rv) { return true }
        return remove(&word, endings: perfectiveGerundGroup2, from: rv)
    }

    private static func removeAdjectival(_ word: inout [Character], _ rv: Int) -> Bool {
        guard remove(&word, endings: adjective, from: rv) else { return false }
        if !removePrecededByAYa(&word, endings: participleGroup1, from: rv) {
            _ = remove(&word, endings: participleGroup2, from: rv)
        }
        return true
    }

    private static func removeVerb(_ word: inout [Character], _ rv: Int) -> Bool {
        if removePrecededByAYa(&word, endings: verbGroup1, from: rv) { return true }
        return remove(&word, endings: verbGroup2, from: rv)
    }

    // MARK: Наборы окончаний (длинные проверяются первыми)

    private static let vowels: Set<Character> = ["а", "е", "и", "о", "у", "ы", "э", "ю", "я"]

    private static func sorted(_ endings: [String]) -> [[Character]] {
        endings.sorted { $0.count > $1.count }.map(Array.init)
    }

    private static let perfectiveGerundGroup1 = sorted(["вшись", "вши", "в"])
    private static let perfectiveGerundGroup2 = sorted(["ившись", "ывшись", "ивши", "ывши", "ив", "ыв"])

    private static let adjective = sorted([
        "ими", "ыми", "его", "ого", "ему", "ому",
        "ее", "ие", "ые", "ое", "ей", "ий", "ый", "ой",
        "ем", "им", "ым", "ом", "их", "ых", "ую", "юю",
        "ая", "яя", "ою", "ею"
    ])

    private static let participleGroup1 = sorted(["ющ", "ем", "нн", "вш", "щ"])
    private static let participleGroup2 = sorted(["ующ", "ивш", "ывш"])

    private static let reflexive = sorted(["ся", "сь"])

    private static let verbGroup1 = sorted([
        "ешь", "нно", "ете", "йте",
        "ла", "на", "ли", "ем", "ло", "но", "ет", "ют", "ны", "ть",
        "й", "л", "н"
    ])

    private static let verbGroup2 = sorted([
        "ейте", "уйте",
        "ила", "ыла", "ена", "ите", "или", "ыли", "ило", "ыло", "ено",
        "ует", "уют", "ить", "ыть", "ишь", "ены",
        "ей", "уй", "ил", "ыл", "им", "ым", "ен", "ят", "ит", "ыт", "ую",
        "ю"
    ])

    private static let noun = sorted([
        "иями",
        "ями", "ами", "ией", "иям", "ием", "иях",
        "ев", "ов", "ие", "ье", "еи", "ии", "ей", "ой", "ий",
        "ям", "ем", "ам", "ом", "ах", "ях", "ию", "ью", "ия", "ья",
        "а", "е", "и", "й", "о", "у", "ы", "ь", "ю", "я"
    ])

    private static let superlative = sorted(["ейше", "ейш"])
    private static let derivational = sorted(["ость", "ост"])
}

private extension NSTextCheckingResult {
    /// Текст указанной группы совпадения.
    func group(_ index: Int, in text: String) -> String? {
        let nsRange = range(at: index)
        guard nsRange.location != NSNotFound,
              let swiftRange = Range(nsRange, in: text) else { return nil }
        return String(text[swiftRange])
    }
}
