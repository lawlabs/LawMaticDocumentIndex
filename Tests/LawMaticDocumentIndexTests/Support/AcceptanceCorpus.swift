import CoreGraphics
import CoreText
import CryptoKit
import Foundation
import SQLite
@testable import LawMaticDocumentIndex

/// Воспроизводимый приёмочный корпус во временной папке.
/// Не использует домашние каталоги пользователя и старые тестовые SQLite.
final class AcceptanceCorpus {
    static let workRootId = "acceptance-work-root"
    static let archiveRootId = "acceptance-archive-root"
    static let legacyMarker = "птерозавр-v1-контроль"

    let directoryURL: URL
    let location: DocumentIndexLocation
    let macAWork: URL
    let macAArchive: URL
    let macBDocuments: URL

    let claimText = "Исковое заявление содержит контрольное слово кварцозавр и сумму 100 000 рублей."
    let contract200 = "Договор поставки на сумму 200 000 рублей между сторонами."
    let contract900 = "Договор поставки на сумму 900 000 рублей между сторонами."
    let childText = "Документ вложенного дела ChildCase."
    let case10Text = "Ловушка префикса Case-10: этот файл не принадлежит Case-1."
    let archiveClaimText = "Архивная копия иска с тем же относительным путём, но другим корнем."
    let specialName = "договор % & # +.txt"
    let specialText = "Имя файла с кириллицей, пробелом и символами % & # +."
    let emojiText = "Смайлик для UTF-16: 🦕 и комбинирующий знак е\u{0301}."

    var lateMarkerText: String {
        Array(repeating: "абзац ", count: 400).joined() + "zzzUNIQUECODEzzz"
    }

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LawMaticAcceptance-\(UUID().uuidString)", isDirectory: true)
        let fixture = directoryURL.appendingPathComponent("fixture", isDirectory: true)
        location = DocumentIndexLocation(
            shareDirectory: directoryURL.appendingPathComponent("index", isDirectory: true)
        )
        macAWork = fixture.appendingPathComponent("mac-a/Work", isDirectory: true)
        macAArchive = fixture.appendingPathComponent("mac-a/Archive", isDirectory: true)
        macBDocuments = fixture.appendingPathComponent("mac-b/Documents", isDirectory: true)

        let fm = FileManager.default
        try fm.createDirectory(at: location.shareDirectory, withIntermediateDirectories: true)
        try writeWorkTree(at: macAWork)
        try writeFile(macAArchive.appendingPathComponent("Client-1/Case-1/claim.txt"), archiveClaimText)
        try copyDirectory(macAWork, to: macBDocuments)
    }

    deinit {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    func fileSHA256(at url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    func writeNeighboringV1(marker: String = AcceptanceCorpus.legacyMarker) throws {
        let db = try SQLite.Connection(location.shareDirectory.appendingPathComponent("LawMaticCaseDatabase.sqlite").path)
        try db.execute("""
            CREATE TABLE documents_catalog (id TEXT, relative_path TEXT);
            CREATE TABLE document_text_variants (text_content TEXT);
            """)
        try db.run("INSERT INTO document_text_variants (text_content) VALUES (?)", marker)
    }

    func writeCorruptV1() throws {
        try Data("это не sqlite".utf8).write(to: location.shareDirectory.appendingPathComponent("LawMaticCaseDatabase.sqlite"))
    }

    private func writeWorkTree(at work: URL) throws {
        let case1 = work.appendingPathComponent("Client-1/Case-1", isDirectory: true)
        try writeFile(case1.appendingPathComponent("claim.txt"), claimText)
        try writeFile(case1.appendingPathComponent("contract.txt"), contract200)
        try writeFile(case1.appendingPathComponent("copy-same-text.txt"), contract200)
        try writeFile(case1.appendingPathComponent("late-marker.txt"), lateMarkerText)
        try writeFile(case1.appendingPathComponent("ChildCase/child.txt"), childText)
        try writeFile(case1.appendingPathComponent(specialName), specialText)
        try writeFile(case1.appendingPathComponent("emoji.txt"), emojiText)
        try writeFile(case1.appendingPathComponent("empty.txt"), "")
        try writeFile(case1.appendingPathComponent("unsupported.xyz"), Data([0x00, 0x01, 0x02, 0xFF]))
        try writeFile(case1.appendingPathComponent("corrupt.pdf"), Data("not-a-pdf".utf8))
        try makePDF(case1.appendingPathComponent("mixed.pdf"), nativePages: 1, scannedPages: 2)
        try writeFile(work.appendingPathComponent("Client-2/Case-2/contract.txt"), contract900)
        try writeFile(work.appendingPathComponent("Case-10/other.txt"), case10Text)
    }

    private func writeFile(_ url: URL, _ text: String) throws {
        try writeFile(url, Data(text.utf8))
    }

    private func writeFile(_ url: URL, _ data: Data) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }

    private func copyDirectory(_ source: URL, to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private func makePDF(_ url: URL, nativePages: Int, scannedPages: Int) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var mediaBox = CGRect(x: 0, y: 0, width: 600, height: 800)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw TestError.message("не удалось создать PDF \(url.lastPathComponent)")
        }
        for index in 0..<(nativePages + scannedPages) {
            context.beginPDFPage(nil)
            if index < nativePages {
                let string = NSAttributedString(string: "Сопроводительное письмо", attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 18, nil)
                ])
                context.textPosition = CGPoint(x: 40, y: 740)
                CTLineDraw(CTLineCreateWithAttributedString(string), context)
            } else {
                context.fill(CGRect(x: 40, y: 100, width: 300, height: 20))
            }
            context.endPDFPage()
        }
        context.closePDF()
    }
}
