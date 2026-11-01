import Foundation
import SQLite

extension DocumentIndexStore {
    /// Coherent private recovery copy for a reader. VACUUM INTO reads committed WAL
    /// pages while leaving the source connection SQLITE_OPEN_READONLY. The destination
    /// is a new standalone local file, never a shared writer database.
    public func createRecoverySnapshot(at destination: URL) throws {
        guard destination.standardizedFileURL != databaseURL.standardizedFileURL,
              !FileManager.default.fileExists(atPath: destination.path) else {
            throw DocumentIndexError.invalidArgument("Recovery snapshot requires a new local file")
        }
        try db().run("VACUUM INTO ?", destination.path)
    }
}
