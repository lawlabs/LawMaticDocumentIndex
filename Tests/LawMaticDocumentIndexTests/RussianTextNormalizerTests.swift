import Foundation
import Testing
@testable import LawMaticDocumentIndex

@Test("Морфология: словоформы сводятся к одной основе")
func морфологияСловоформыСводятсяКОднойОснове() {
    let groups: [[String]] = [
        ["истец", "истца", "истцу", "истцом", "истцы"],
        ["договор", "договора", "договору", "договоров", "договорам"],
        ["взыскание", "взыскания", "взысканию", "взыскании"],
        ["неосновательное", "неосновательного", "неосновательным"],
        ["обогащение", "обогащения", "обогащением"],
        ["решение", "решения", "решением", "решении"],
        ["протокол", "протокола", "протоколом", "протоколы"]
    ]
    for forms in groups {
        let stems = Set(forms.map { RussianTextNormalizer.normalizeToken($0) })
        #expect(stems.count == 1, "формы \(forms.first!) дают одну основу, получено \(stems.sorted())")
    }
}

@Test("Морфология: ё сводится к е")
func морфологияЁСводитсяКЕ() {
    #expect(RussianTextNormalizer.normalizeToken("ёлка") == RussianTextNormalizer.normalizeToken("елка"), "ёлка = елка")
    #expect(RussianTextNormalizer.normalizeToken("Пётр") == RussianTextNormalizer.normalizeToken("Петр"), "Пётр = Петр")
}

@Test("Морфология: разные корни не схлопываются")
func морфологияРазныеКорниНеСхлопываются() {
    let pairs = [("иск", "искусство"), ("суд", "судно"), ("дом", "документ")]
    for (left, right) in pairs {
        #expect(
            RussianTextNormalizer.normalizeToken(left) != RussianTextNormalizer.normalizeToken(right),
            "«\(left)» и «\(right)» не должны совпадать"
        )
    }
}

@Test("Служебные слова отбрасываются из запроса")
func служебныеСловаОтбрасываютсяИзЗапроса() {
    let stems = RussianTextNormalizer.queryStems(from: "Куда делись деньги по договору уступки к РН+?")
    #expect(!stems.contains("куд"), "вопросительное «куда» отброшено")
    #expect(!stems.contains("по"), "предлог «по» отброшен")
    #expect(!stems.contains("к"), "предлог «к» отброшен")
    #expect(stems.contains("договор"), "значимое «договор» осталось")
    #expect(stems.contains("уступк"), "значимое «уступки» осталось")

    // Запрос целиком из служебных слов не должен превращаться в пустой.
    #expect(!RussianTextNormalizer.queryStems(from: "что и как").isEmpty, "запрос из служебных слов не пустеет")
}

@Test("Даты распознаются и сводятся к одному токену")
func датыРаспознаютсяИСводятсяКОдномуТокену() {
    #expect(RussianTextNormalizer.dateTokens(in: "от 31.10.2022") == ["дата20221031"], "цифровая дата")
    #expect(RussianTextNormalizer.dateTokens(in: "от 31.10.22") == ["дата20221031"], "двузначный год")
    #expect(RussianTextNormalizer.dateTokens(in: "31 октября 2022 года") == ["дата20221031"], "словесный месяц")
    #expect(RussianTextNormalizer.dateTokens(in: "дело А40-59614/2023") == [], "номер дела не дата")
    #expect(RussianTextNormalizer.dateTokens(in: "с 01.01.2020 по 31.10.2022").count == 2, "две даты в диапазоне")
}

@Test("Сниппет строится из оригинального текста")
func сниппетСтроитсяИзОригинальногоТекста() {
    let text = "Общество обратилось с иском о взыскании неосновательного обогащения."
    let snippet = RussianTextNormalizer.snippet(
        from: text,
        matching: RussianTextNormalizer.queryStems(from: "взыскание неосновательного обогащения"),
        radius: 80
    )
    #expect(snippet.contains("[взыскании]"), "подсвечена исходная словоформа, а не основа")
    #expect(!snippet.contains("взыскан "), "нормализованный текст в сниппет не попадает")
}
