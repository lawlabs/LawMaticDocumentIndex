import Foundation

/// Единые правила относительных путей индекса: ingest, rename и scope.
///
/// Пустой путь — корень рабочей папки или папка-дело. Имя документа пустым быть
/// не может. Абсолютный путь, `..`, `.` и NUL в относительном поле отвергаются
/// до записи в каталог. Регистр не меняется: на case-sensitive томе это разные файлы.
public enum DocumentIndexPath: Sendable {
    /// Папка или корень: `""` допустим.
    public static func validateFolder(_ path: String) throws -> String {
        try validate(path, allowEmpty: true)
    }

    /// Документ: последним компонентом должно быть имя файла.
    public static func validateDocument(_ path: String) throws -> String {
        try validate(path, allowEmpty: false)
    }

    /// NFC без ведущих/хвостовых `/`. Не проверяет `..` и абсолютность —
    /// для уже сохранённых значений и отображения.
    public static func canonicalize(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping
            .split(separator: "/", omittingEmptySubsequences: true)
            .joined(separator: "/")
    }

    public static func isUnavailableURL(_ url: URL) -> Bool {
        url.scheme == "lawmatic-document"
    }

    public static func unavailableURL(workspaceRootId: String, relativePath: String) -> URL {
        var components = URLComponents()
        components.scheme = "lawmatic-document"
        components.host = "unavailable"
        components.path = "/" + workspaceRootId + "/" + relativePath
        return components.url ?? URL(string: "lawmatic-document://unavailable")!
    }

    private static func validate(_ path: String, allowEmpty: Bool) throws -> String {
        if path.contains("\0") {
            throw DocumentIndexError.invalidArgument("относительный путь не может содержать NUL")
        }
        // Не trim-ить пробелы: на APFS `report.txt` и `report.txt ` — разные файлы.
        // Абсолютность проверяем по исходной строке, иначе ` /tmp` станет `/tmp`.
        if looksAbsolute(path) {
            throw DocumentIndexError.invalidArgument("относительный путь не может быть абсолютным")
        }
        let parts = path.precomposedStringWithCanonicalMapping
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        for part in parts {
            if part == ".." || part == "." {
                throw DocumentIndexError.invalidArgument("путь должен находиться внутри рабочего корня")
            }
        }
        if parts.isEmpty {
            if allowEmpty { return "" }
            throw DocumentIndexError.invalidArgument("пустой путь документа")
        }
        return parts.joined(separator: "/")
    }

    private static func looksAbsolute(_ path: String) -> Bool {
        if path.hasPrefix("/") || path.hasPrefix("~") { return true }
        if path.contains("://") { return true }
        if path.count >= 2 {
            let second = path[path.index(path.startIndex, offsetBy: 1)]
            if second == ":" { return true }
        }
        return false
    }
}
