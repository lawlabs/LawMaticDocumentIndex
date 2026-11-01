import Foundation

/// Расположение общей базы: `~/LawMatic Share/LawMaticDocumentIndex.sqlite`.
///
/// Домашний каталог берётся из записи `passwd`, а не из
/// `FileManager.homeDirectoryForCurrentUser`: в App Sandbox последний указывает на
/// контейнер приложения, и разные приложения LawMatic разошлись бы по разным папкам.
/// Sandbox-клиент всё равно должен получить доступ к папке через security-scoped
/// bookmark — этот тип только вычисляет пути, доступом не занимается.
public enum DatabaseLocation {
    public static let shareDirectoryName = "LawMatic Share"
    public static let modelsDirectoryName = "Models"

    public static var posixHomeDirectoryURL: URL {
        if let passwd = getpwuid(getuid()), let home = passwd.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: home), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    public static var defaultShareDirectoryURL: URL {
        posixHomeDirectoryURL.appendingPathComponent(shareDirectoryName, isDirectory: true)
    }

    public static func databaseURL(in shareDirectory: URL = defaultShareDirectoryURL) -> URL {
        shareDirectory.appendingPathComponent(DocumentIndexSchema.fileName, isDirectory: false)
    }

    public static func manifestURL(in shareDirectory: URL = defaultShareDirectoryURL) -> URL {
        shareDirectory.appendingPathComponent(DocumentIndexSchema.manifestFileName, isDirectory: false)
    }

    /// Общий кеш весов моделей эмбеддингов, чтобы каждый клиент не скачивал свой экземпляр.
    public static func modelsDirectoryURL(in shareDirectory: URL = defaultShareDirectoryURL) -> URL {
        shareDirectory.appendingPathComponent(modelsDirectoryName, isDirectory: true)
    }


}

/// Каталог индекса и манифеста.
/// Путь внедряется в тестах явно; не читать UserDefaults ради проверки.
public struct DocumentIndexLocation: Sendable, Equatable {
    public var shareDirectory: URL

    public init(shareDirectory: URL) {
        self.shareDirectory = shareDirectory
    }

    public var databaseURL: URL { DatabaseLocation.databaseURL(in: shareDirectory) }
    public var manifestURL: URL { DatabaseLocation.manifestURL(in: shareDirectory) }
}

/// Файлы одного поколения SQLite: сам файл плюс WAL/SHM/journal.
public enum DocumentIndexDatabaseFiles {
    public static func sidecarURLs(for databaseURL: URL) -> [URL] {
        let path = databaseURL.path
        return [
            databaseURL,
            URL(fileURLWithPath: path + "-wal"),
            URL(fileURLWithPath: path + "-shm"),
            URL(fileURLWithPath: path + "-journal")
        ]
    }

    /// Удаляет поколение. Вызывать только после `close()` писателя.
    public static func removeGeneration(at databaseURL: URL) throws {
        let fm = FileManager.default
        for url in sidecarURLs(for: databaseURL) where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
    }

    /// Переносит поколение в соседнюю папку, не оставляя открытый WAL без основного файла.
    @discardableResult
    public static func retireGeneration(at databaseURL: URL, extraFiles: [URL] = []) throws -> URL? {
        let fm = FileManager.default
        let existing = (sidecarURLs(for: databaseURL) + extraFiles).filter { fm.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return nil }

        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let destDir = databaseURL
            .deletingLastPathComponent()
            .appendingPathComponent("LawMaticDocumentIndex-retired-\(stamp)", isDirectory: true)
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        for url in existing {
            try fm.moveItem(at: url, to: destDir.appendingPathComponent(url.lastPathComponent))
        }
        return destDir
    }
}
