import Foundation
import Testing
@testable import LawMaticDocumentIndex

@Test("Выражение MATCH по ступеням")
func выражениеMatchПоСтупеням() {
    let stems = ["договор", "уступк"]
    #expect(
        DocumentSearchQuery.matchExpression(stems: stems, mode: .allWords) == "\"договор\"* AND \"уступк\"*",
        "строгая ступень объединяет через AND"
    )
    #expect(
        DocumentSearchQuery.matchExpression(stems: stems, mode: .anyWord) == "\"договор\"* OR \"уступк\"*",
        "ослабленная ступень объединяет через OR"
    )
    // На одном слове ослабленная ступень совпала бы со строгой, поэтому пуста.
    #expect(
        DocumentSearchQuery.matchExpression(stems: ["договор"], mode: .anyWord) == "",
        "ослабленная ступень на одном слове не строится"
    )
    #expect(DocumentSearchQuery.matchExpression(stems: [], mode: .allWords) == "", "пустой запрос не строится")
}

@Test("Экранирование в шаблонах LIKE")
func экранированиеВШаблонахLike() {
    #expect(DocumentSearchQuery.escapeForLike("Дело_1") == "Дело\\_1", "подчёркивание экранируется")
    #expect(DocumentSearchQuery.escapeForLike("100%") == "100\\%", "процент экранируется")
    #expect(DocumentSearchQuery.escapeForLike("a\\b") == "a\\\\b", "обратная косая экранируется")
}

@Test("Изоляция области: одинаковый путь в двух рабочих папках")
func изоляцияОбластиОдинаковыйПутьВДвухРабочихПапках() throws {
    let database = try TestDatabase()
    try database.addCase(id: "case-A", workspaceRootId: "root-1", rootPath: "Клиенты")
    try database.addCase(id: "case-B", workspaceRootId: "root-2", rootPath: "Клиенты")

    try database.addDocument(
        id: "doc-A", caseId: "case-A", rootFolderPath: "Клиенты",
        folderPath: "Клиенты/Иски", relativePath: "Иски/договор.docx",
        fileName: "договор.docx", text: "Договор поставки клиента первого корня."
    )
    try database.addDocument(
        id: "doc-B", caseId: "case-B", rootFolderPath: "Клиенты",
        folderPath: "Клиенты/Иски", relativePath: "Иски/договор.docx",
        fileName: "договор.docx", text: "Договор поставки клиента второго корня."
    )

    let stems = RussianTextNormalizer.queryStems(from: "договор поставки")

    guard let mixed = DocumentSearchQuery.ftsStatement(
        stems: stems, mode: .allWords, variantFilter: .original, scope: .everything
    ) else { throw TestError.message("не построился запрос") }
    #expect(try database.paths(mixed).count == 2, "без области находятся оба документа")

    guard let isolated = DocumentSearchQuery.ftsStatement(
        stems: stems, mode: .allWords, variantFilter: .original,
        scope: .folderRecursive(workspaceRootId: "root-1", relativePath: "Клиенты")
    ) else { throw TestError.message("не построился запрос") }
    #expect(try database.paths(isolated).count == 1, "область по первому корню возвращает один документ")

    guard let byCase = DocumentSearchQuery.ftsStatement(
        stems: stems, mode: .allWords, variantFilter: .original, scope: .wholeCase(caseId: "case-B")
    ) else { throw TestError.message("не построился запрос") }
    #expect(try database.paths(byCase).count == 1, "область по делу возвращает один документ")
}

@Test("Рекурсивная область от самого Workspace Root")
func рекурсивнаяОбластьОтСамогоWorkspaceRoot() throws {
    let database = try TestDatabase()
    try database.addCase(id: "case-1", workspaceRootId: "root-1", rootPath: "Клиент/Дело")
    try database.addCase(id: "case-2", workspaceRootId: "root-2", rootPath: "Другой клиент")
    try database.addDocument(
        id: "doc-1", caseId: "case-1", rootFolderPath: "Клиент/Дело",
        folderPath: "Клиент/Дело/Материалы", relativePath: "Материалы/иск.docx",
        fileName: "иск.docx", text: "Исковое заявление о взыскании долга."
    )
    try database.addDocument(
        id: "doc-2", caseId: "case-2", rootFolderPath: "Другой клиент",
        folderPath: "Другой клиент/Материалы", relativePath: "Материалы/иск.docx",
        fileName: "иск.docx", text: "Исковое заявление о взыскании долга."
    )

    let stems = RussianTextNormalizer.queryStems(from: "исковое заявление")
    guard let statement = DocumentSearchQuery.ftsStatement(
        stems: stems,
        mode: .allWords,
        variantFilter: .original,
        scope: .folderRecursive(workspaceRootId: "root-1", relativePath: "")
    ) else { throw TestError.message("не построился запрос") }

    #expect(
        try database.paths(statement) == ["Материалы/иск.docx"],
        "пустой относительный путь охватывает весь выбранный root и только его"
    )
}

@Test("Подчёркивание в имени папки не работает как маска")
func подчёркиваниеВИмениПапкиНеРаботаетКакМаска() throws {
    let database = try TestDatabase()
    try database.addCase(id: "case-1", workspaceRootId: "root-1", rootPath: "Дело_1")
    try database.addCase(id: "case-2", workspaceRootId: "root-1", rootPath: "ДелоX1")

    try database.addDocument(
        id: "doc-1", caseId: "case-1", rootFolderPath: "Дело_1",
        folderPath: "Дело_1/Материалы", relativePath: "Материалы/иск.docx",
        fileName: "иск.docx", text: "Исковое заявление по первому делу."
    )
    try database.addDocument(
        id: "doc-2", caseId: "case-2", rootFolderPath: "ДелоX1",
        folderPath: "ДелоX1/Материалы", relativePath: "Материалы/иск.docx",
        fileName: "иск.docx", text: "Исковое заявление по второму делу."
    )

    let stems = RussianTextNormalizer.queryStems(from: "исковое заявление")
    guard let statement = DocumentSearchQuery.ftsStatement(
        stems: stems, mode: .allWords, variantFilter: .original,
        scope: .folderRecursive(workspaceRootId: "root-1", relativePath: "Дело_1")
    ) else { throw TestError.message("не построился запрос") }

    #expect(try database.paths(statement).count == 1, "«ДелоX1» не попадает в область «Дело_1»")
}

@Test("Морфологический поиск находит другую словоформу")
func морфологическийПоискНаходитДругуюСловоформу() throws {
    let database = try TestDatabase()
    try database.addCase(id: "case-1", workspaceRootId: "root-1", rootPath: "Дело")
    try database.addDocument(
        id: "doc-1", caseId: "case-1", rootFolderPath: "Дело",
        folderPath: "Дело", relativePath: "справка.docx", fileName: "справка.docx",
        text: "Иск о взыскании неосновательного обогащения удовлетворён."
    )

    // Запрос в именительном падеже, текст — в предложном и родительном.
    let stems = RussianTextNormalizer.queryStems(from: "взыскание неосновательного обогащения")
    guard let statement = DocumentSearchQuery.ftsStatement(
        stems: stems, mode: .allWords, variantFilter: .original, scope: .wholeCase(caseId: "case-1")
    ) else { throw TestError.message("не построился запрос") }
    #expect(try database.paths(statement).count == 1, "падежи сходятся")
}

@Test("Поиск по дате находит документ с другой записью той же даты")
func поискПоДатеНаходитДокументСДругойЗаписьюТойЖеДаты() throws {
    let database = try TestDatabase()
    try database.addCase(id: "case-1", workspaceRootId: "root-1", rootPath: "Дело")
    try database.addDocument(
        id: "doc-1", caseId: "case-1", rootFolderPath: "Дело",
        folderPath: "Дело", relativePath: "протокол.pdf", fileName: "протокол.pdf",
        text: "Протокол общего собрания от 31 октября 2022 года."
    )

    let stems = RussianTextNormalizer.queryStems(from: "протокол 31.10.2022")
    guard let statement = DocumentSearchQuery.ftsStatement(
        stems: stems, mode: .allWords, variantFilter: .original, scope: .wholeCase(caseId: "case-1")
    ) else { throw TestError.message("не построился запрос") }
    #expect(try database.paths(statement).count == 1, "«31.10.2022» находит «31 октября 2022»")
}
