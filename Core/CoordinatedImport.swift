import Foundation

extension VaultStore {
    func importCoordinated(_ url: URL, parent: UUID?) throws -> UUID {
        var coordinationError: NSError?
        var outcome: Result<UUID, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { available in
            outcome = Result { try importFile(available, versionOf: parent) }
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
