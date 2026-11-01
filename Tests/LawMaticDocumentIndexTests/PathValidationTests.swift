import Foundation
import Testing
@testable import LawMaticDocumentIndex

@Test("Пустой путь допустим для папки и запрещён для документа")
func пустойПутьПапкиИДокумента() throws {
    #expect(try DocumentIndexPath.validateFolder("") == "")
    #expect(try DocumentIndexPath.validateFolder(" ") == " ")
    #expect(try DocumentIndexPath.validateFolder("  ") == "  ")
    #expect(try DocumentIndexPath.validateFolder("Дело/вложенная") == "Дело/вложенная")
    #expect(throws: DocumentIndexError.self) {
        _ = try DocumentIndexPath.validateDocument("")
    }
    #expect(try DocumentIndexPath.validateDocument("Дело/иск.txt") == "Дело/иск.txt")
}

@Test("Пробелы в имени файла остаются частью координаты")
func пробелыВИмениФайлаНеОбрезаются() throws {
    #expect(try DocumentIndexPath.validateDocument("case/report.txt ") == "case/report.txt ")
    #expect(try DocumentIndexPath.validateDocument("case/report.txt") == "case/report.txt")
    #expect(try DocumentIndexPath.validateFolder("Client ") == "Client ")
    #expect(try DocumentIndexPath.validateFolder("Client ") != "")
    #expect(try DocumentIndexPath.validateDocument(" /tmp/a.txt") == " /tmp/a.txt")
}

@Test("Относительный путь отвергает .., точку, NUL и абсолютные формы")
func относительныйПутьОтвергаетОбход() throws {
    for path in ["../secret.txt", "Дело/../secret.txt", "./file.txt", "Дело/./a.txt"] {
        #expect(throws: DocumentIndexError.self) {
            _ = try DocumentIndexPath.validateDocument(path)
        }
    }
    #expect(throws: DocumentIndexError.self) {
        _ = try DocumentIndexPath.validateFolder("..\0hidden")
    }
    #expect(throws: DocumentIndexError.self) {
        _ = try DocumentIndexPath.validateDocument("a\0b.txt")
    }
    for path in ["/tmp/a.txt", "~/Work/a.txt", "file:///tmp/a.txt", "C:\\Work\\a.txt"] {
        #expect(throws: DocumentIndexError.self) {
            _ = try DocumentIndexPath.validateDocument(path)
        }
    }
}

@Test("Нормализация Unicode NFC без принудительного lowercase")
func нормализацияПутиБезLowercase() throws {
    let nfd = "е\u{0301}лка/Договор.TXT"
    let canonical = try DocumentIndexPath.validateDocument(nfd)
    #expect(canonical == "ёлка/Договор.TXT" || canonical.contains("Договор.TXT"))
    #expect(canonical.contains("Договор.TXT"))
    #expect(!canonical.contains("договор.txt"))
    #expect(DocumentIndexPath.canonicalize("///Дело///папка///") == "Дело/папка")
}

@Test("ingest и scope отвергают абсолютный и выход через ..")
func ingestОтвергаетНекорректныйПуть() async throws {
    let temp = TemporaryDatabase()
    let store = try await temp.openWriter()
    let root = try await store.registerWorkspaceRoot(name: "Work", localPath: "/tmp/work")
    await #expect(throws: DocumentIndexError.self) {
        _ = try await store.upsertWorkspaceDocument(
            workspaceRootId: root.id,
            relativePath: "/etc/passwd",
            fileSize: 1,
            fileModifiedAt: Date(),
            fileHash: nil
        )
    }
    await #expect(throws: DocumentIndexError.self) {
        _ = try await store.moveFolder(
            workspaceRootId: root.id,
            relativePath: "Дело",
            toRootId: root.id,
            destinationPath: "../outside"
        )
    }
    let emptyHits = try await store.searchChunksKeyword(
        query: "договор",
        scope: .folderPath(workspaceRootId: root.id, relativePath: "../x", recursive: true)
    )
    #expect(emptyHits.hits.isEmpty)
    await store.close()
}

@Test("Два файла с пробелом в имени получают разные document ID")
func дваФайлаСПробеломВИмениНеСклеиваются() async throws {
    let temp = TemporaryDatabase()
    let store = try await temp.openWriter()
    let root = try await store.registerWorkspaceRoot(name: "Work", localPath: "/tmp/work-space")
    let first = try await store.upsertWorkspaceDocument(
        workspaceRootId: root.id,
        relativePath: "case/report.txt",
        fileSize: 3,
        fileModifiedAt: Date(),
        fileHash: "hash-plain"
    )
    let second = try await store.upsertWorkspaceDocument(
        workspaceRootId: root.id,
        relativePath: "case/report.txt ",
        fileSize: 4,
        fileModifiedAt: Date(),
        fileHash: "hash-spaced"
    )
    #expect(first.id != second.id)
    #expect(first.relativePath == "case/report.txt")
    #expect(second.relativePath == "case/report.txt ")
    let folder = try await store.ensureFolder(workspaceRootId: root.id, relativePath: "Client ")
    #expect(folder.relativePath == "Client ")
    await store.close()
}
