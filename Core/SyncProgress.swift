import Foundation

struct SyncProgressState {
    var title = "Connexion au fournisseur…"
    var detail: String?
    var completed = 0
    var total: Int?
}

final class SyncProgressMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = SyncProgressState()
    var snapshot: SyncProgressState { lock.withLock { value } }

    func begin(_ title: String, total: Int? = nil) {
        lock.withLock { value = SyncProgressState(title: title, total: total) }
    }

    func describe(_ detail: String) { lock.withLock { value.detail = detail } }

    func advance() { lock.withLock { value.completed += 1 } }
}

extension VaultStore {
    func lastSuccessfulSync() throws -> Date? {
        let config = try settings()
        let file = root.appendingPathComponent("last-sync.v1")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let dates = try Self.unpack([String: Date].self, data: Data(contentsOf: file), keys: keys, purpose: "last-sync")
        return dates[config.destination]
    }

    func recordSuccessfulSync(for destination: String) throws {
        let file = root.appendingPathComponent("last-sync.v1")
        var dates = FileManager.default.fileExists(atPath: file.path)
            ? try Self.unpack([String: Date].self, data: Data(contentsOf: file), keys: keys, purpose: "last-sync") : [:]
        dates[destination] = .now
        let bytes = try Self.pack(dates, keys: keys, purpose: "last-sync")
        try gate.authorized { try VaultFiles.save(bytes, to: file) }
    }
}
