import Foundation
import Testing
@testable import LawMaticDocumentIndex

// Строки — из настоящих текстовых слоев дела: распоряжения управы и протокол
// правления, «распознанные» чужой программой латиницей.
private let order = """
A HPABHTEJIbCTBO MOCKBbl yilPABA PAMOHA KOHEKOBO POPOVA MOCKBbl K)ro-3ana4Hbiw azjMHHHCTpaTHBHbiw OKpyr \
PACnOPOEHHE No 06 onpe^ejieHHH BpeMCHHoii ynpaBJiaiomeH opraHHsaujiH no 3KcnjiyaTaijHH MHoroKBapTHpHoro \
ZKHjioro aoMa no aapecy: yji. AKaAeMHKa KanHUbi, a. 18
"""
private let orderSecondPage = """
Bonpoc BHecen: PacnopH/KCHne corjiacoBano: riepBbin saMecTHTejib rjiaBbi ynpaBbi paiioHa KoHbKOBo \
TopoAa MocKBbi no Bonpocaivi >KHjiHiHHO-KOMMynajibHoro xosflfiCTBa
"""
private let minutes = """
ftPoToKon J\\! _ 3aceaalMt rlpaBneI{E xI,tJIt{IIIro-cTpoltreJr6Irofo (oonepaTlrBa <MafiCrcI.Ifi-2) \
r. Mocraa 17 utorur 2025 roAa flpucyrcrBoBzrJrrr: '{neHrr npaBneHnr {CK
"""

@Test("Мусорный слой: распоряжение и протокол латиницей распознаются как мусор")
func мусорныйСлойРаспознаётся() {
    for (name, text) in [("распоряжение", order), ("вторая страница", orderSecondPage), ("протокол", minutes)] {
        let assessment = TextLayerQuality.assess(text)
        #expect(assessment.isGarbled, "\(name): \(assessment)")
    }
}

@Test("Мусорный слой: настоящий текст не трогаем")
func настоящийТекстНеМусор() {
    let samples: [(String, String)] = [
        ("русский", "Распоряжение Управы района Коньково от 27.07.2026 № 72-Р об определении временной управляющей организации для многоквартирного дома по адресу: ул. Академика Капицы, д. 18."),
        ("английский договор", "This Agreement shall be governed by the laws of England and Wales. Any dispute arising out of or in connection with this Agreement, including any question regarding its existence, validity or termination, shall be referred to arbitration."),
        ("реквизиты", "Beneficiary: LAWMATIC LLC IBAN DE89370400440532013000 SWIFT COBADEFFXXX Bank: COMMERZBANK AG FRANKFURT Account 0532013000 Reference INVOICE 2026 OCTOBER PAYMENT"),
        ("немецкий", "Der Vertrag tritt mit seiner Unterzeichnung in Kraft und gilt bis zur vollständigen Erfüllung aller Verpflichtungen durch die Parteien gemäß den Bestimmungen."),
        ("русский с английскими словами", "Сторона обязуется предоставить доступ к сервисам Microsoft Office, iPhone и MacBook Pro в течение пяти рабочих дней с момента подписания настоящего соглашения."),
        ("английский с iPhone и McDonald", "The iPhone was purchased at the McDonald store on Main Street, and the receipt was provided to the court as evidence of the date of the transaction."),
        ("штамп", "М.П. 72-Р")
    ]
    for (name, text) in samples {
        let assessment = TextLayerQuality.assess(text)
        #expect(!assessment.isGarbled, "\(name): \(assessment)")
    }
}

@Test("Мусорный слой: рваный регистр и цифра внутри слова")
func рваныйРегистр() {
    #expect(TextLayerQuality.isBroken("yilPABA"))
    #expect(TextLayerQuality.isBroken("PACnOPOEHHE"))
    #expect(TextLayerQuality.isBroken("3ana4Hbiw"))
    #expect(!TextLayerQuality.isBroken("SWIFT"))
    #expect(!TextLayerQuality.isBroken("Agreement"))
    #expect(!TextLayerQuality.isBroken("PDFs"))
    #expect(!TextLayerQuality.isBroken("DE89370400440532013000"))
}
