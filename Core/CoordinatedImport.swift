import Foundation

extension VaultStore {
    func importCoordinated(_ url: URL, parent: UUID?, folder: String = "") throws -> UUID {
        try coordinatedRead(url) { try importFile($0, versionOf: parent, folder: folder) }
    }

    func coordinatedRead<T>(_ url: URL, _ read: (URL) throws -> T) throws -> T {
        var coordinationError: NSError?
        var outcome: Result<T, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { available in
            outcome = Result { try read(available) }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else { throw VaultError.unavailable }
        return try outcome.get()
    }

    func labelHistory(_ id: UUID) throws -> [Labels] {
        try gate.check()
        return entries[id]?.document?.previousLabels?.sorted { $0.key.uuidString < $1.key.uuidString }.map(\.value) ?? []
    }
}
